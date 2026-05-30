#!/usr/bin/env node

/**
 * clipboard-server.js
 *
 * 剪贴板图片服务
 * 接收浏览器上传的图片，使用 xclip 写入容器剪贴板
 */

const express = require('express');
const multer = require('multer');
const { spawn } = require('child_process');
const fs = require('fs').promises;
const fsSync = require('fs');
const path = require('path');

const app = express();
const PORT = 10009;

app.use(express.json({ limit: '2mb' }));

// 追踪当前 clipboard-holder 进程 PID，下次启动前主动 kill 旧进程
let holderPid = null;

// 配置 multer 处理文件上传
const upload = multer({
  storage: multer.memoryStorage(),
  limits: {
    fileSize: 10 * 1024 * 1024, // 限制 10MB
    files: 1
  },
  fileFilter: (req, file, cb) => {
    // 只接受图片格式
    if (file.mimetype.startsWith('image/')) {
      cb(null, true);
    } else {
      cb(new Error('只支持图片格式'));
    }
  }
});

// 健康检查端点
app.get('/health', (req, res) => {
  res.json({ status: 'ok', service: 'clipboard-server' });
});

// 文本剪贴板 API：作为 noVNC 原生 clipboard 通道的兜底。
// GET 只读取 X11 CLIPBOARD，不修改容器剪贴板。
app.get('/api/clipboard-text', (req, res) => {
  // 先查询剪贴板支持的格式，若含图像类型则拒绝以文本形式返回，
  // 防止 PNG 二进制被当成 UTF-8 文本同步到本地导致乱码。
  const targetsChild = spawn('xclip', ['-selection', 'clipboard', '-target', 'TARGETS', '-o']);
  const targetChunks = [];
  targetsChild.stdout.on('data', (b) => targetChunks.push(b));
  targetsChild.stderr.on('data', () => {});
  targetsChild.on('error', () => readText());
  targetsChild.on('close', (code) => {
    if (code === 0 && targetChunks.length > 0) {
      const targets = Buffer.concat(targetChunks).toString('utf8');
      if (/image\//i.test(targets)) {
        return res.status(404).json({ error: '剪贴板包含图像，非文本内容' });
      }
    }
    readText();
  });

  function readText() {
    const child = spawn('xclip', ['-selection', 'clipboard', '-target', 'UTF8_STRING', '-o']);
    const chunks = [];
    child.stdout.on('data', (b) => chunks.push(b));
    child.stderr.on('data', () => {});
    child.on('error', () => res.status(500).json({ error: '读取文本剪贴板失败' }));
    child.on('close', (code) => {
      if (code !== 0 || chunks.length === 0) return res.status(404).json({ error: '没有文本剪贴板内容' });
      const buf = Buffer.concat(chunks);
      // 检测二进制内容：若非打印字节（排除常见空白符）占比超 5%，视为二进制数据
      const sampleLen = Math.min(buf.length, 1000);
      let nonPrintable = 0;
      for (let i = 0; i < sampleLen; i++) {
        const b = buf[i];
        if (b < 9 || (b > 13 && b < 32) || b === 127) nonPrintable++;
      }
      if (nonPrintable > sampleLen * 0.05) {
        return res.status(404).json({ error: '剪贴板内容为二进制数据，非文本' });
      }
      res.setHeader('Cache-Control', 'no-store');
      res.json({ text: buf.toString('utf8') });
    });
  }
});

// POST 写入容器 X11 文本剪贴板。图片接口仍独立使用 image/png，避免格式互相误判。
app.post('/api/clipboard-text', async (req, res) => {
  const text = typeof req.body?.text === 'string' ? req.body.text : '';
  if (!text) {
    return res.status(400).json({
      error: '没有文本内容',
      code: 'NO_TEXT'
    });
  }
  if (Buffer.byteLength(text, 'utf8') > 1024 * 1024) {
    return res.status(400).json({
      error: '文本过大（最大 1MB）',
      code: 'TEXT_TOO_LARGE'
    });
  }

  const tempFileName = `clipboard-text-${Date.now()}.txt`;
  const tempPath = path.join('/tmp', tempFileName);

  try {
    await fs.writeFile(tempPath, text, 'utf8');
    const child = spawn('xclip',
      ['-selection', 'clipboard', '-target', 'UTF8_STRING', '-i', tempPath],
      { detached: true, stdio: 'ignore' });
    child.unref();

    setTimeout(() => {
      fs.unlink(tempPath).catch(err => {
        if (err.code !== 'ENOENT') {
          console.warn(`[clipboard] 清理文本临时文件失败: ${err.message}`);
        }
      });
    }, 5000);

    res.json({ success: true, message: '文本已同步到剪贴板', size: Buffer.byteLength(text, 'utf8') });
  } catch (error) {
    console.error('[clipboard] 文本剪贴板写入失败:', error);
    res.status(500).json({ error: '写入文本剪贴板失败', code: 'XCLIP_ERROR' });
  }
});

// 反向：读取容器当前 X11 剪贴板里的 image/png
// 无图时 xclip 退出码非 0 或 stdout 空，返回 404
app.get('/api/clipboard-image', (req, res) => {
  const child = spawn('xclip', ['-selection', 'clipboard', '-target', 'image/png', '-o']);
  const chunks = [];
  child.stdout.on('data', (b) => chunks.push(b));
  child.stderr.on('data', () => {});
  child.on('error', () => res.status(500).end());
  child.on('close', (code) => {
    if (code !== 0 || chunks.length === 0) return res.status(404).end();
    res.setHeader('Content-Type', 'image/png');
    res.setHeader('Cache-Control', 'no-store');
    res.end(Buffer.concat(chunks));
  });
});

// 图片剪贴板 API
app.post('/api/clipboard-image', upload.single('image'), async (req, res) => {
  const startTime = Date.now();

  try {
    if (!req.file) {
      return res.status(400).json({
        error: '没有上传文件',
        code: 'NO_FILE'
      });
    }

    console.log(`[clipboard] 收到图片: ${req.file.mimetype}, ${(req.file.size / 1024).toFixed(2)} KB`);

    // 生成临时文件路径
    const tempFileName = `pasted-image-${Date.now()}.png`;
    const tempPath = path.join('/tmp', tempFileName);

    // 写入临时文件
    await fs.writeFile(tempPath, req.file.buffer);

    console.log(`[clipboard] 临时文件已保存: ${tempPath}`);

    // 同时保存到固定路径，方便终端应用（如 Claude Code）直接用文件路径引用图片
    const fixedPath = '/tmp/clipboard-image.png';
    await fs.writeFile(fixedPath, req.file.buffer);

    // 用 clipboard-holder.py 同时持有 image/png 和 UTF8_STRING（文件路径）
    // 终端 Ctrl+V 得到路径，GIMP 等 GUI 应用 Ctrl+V 得到图片
    try {
      // 主动 kill 旧进程，不依赖 X11 置换机制
      if (holderPid !== null) {
        try { process.kill(holderPid, 'SIGTERM'); } catch (_) {}
        holderPid = null;
      }

      const logFd = fsSync.openSync('/tmp/clipboard-holder.log', 'a');
      let holder;
      try {
        holder = spawn('python3',
          ['/opt/clipboard-holder.py', fixedPath],
          { detached: true, stdio: ['ignore', logFd, logFd], env: { ...process.env, DISPLAY: process.env.DISPLAY || ':1' } });
      } finally {
        fsSync.closeSync(logFd);
      }
      holder.unref();
      holderPid = holder.pid;
      holder.on('exit', () => {
        if (holderPid === holder.pid) holderPid = null;
      });
      holder.on('error', (error) => {
        console.error('[clipboard] clipboard-holder 运行失败:', error);
        if (holderPid === holder.pid) holderPid = null;
      });
      console.log(`[clipboard] clipboard-holder 后台启动 pid=${holder.pid}`);

      // 5 秒后清理临时文件（holder 直接读 fixedPath，不需要 tempPath 持续存在）
      setTimeout(() => {
        fs.unlink(tempPath).catch(err => {
          if (err.code !== 'ENOENT') {
            console.warn(`[clipboard] 清理临时文件失败: ${err.message}`);
          }
        });
      }, 5000);
    } catch (error) {
      console.error('[clipboard] clipboard-holder 启动失败:', error);
      throw new Error('写入剪贴板失败');
    }

    const elapsed = Date.now() - startTime;
    console.log(`[clipboard] 处理完成，文件路径: ${fixedPath}，耗时: ${elapsed}ms`);

    res.json({
      success: true,
      message: '图片已同步到剪贴板',
      filePath: fixedPath,
      size: req.file.size,
      elapsed: elapsed
    });

  } catch (error) {
    console.error('[clipboard] 处理失败:', error);

    res.status(500).json({
      error: error.message,
      code: 'PROCESSING_ERROR'
    });
  }
});

// 错误处理
app.use((error, req, res, next) => {
  if (error instanceof multer.MulterError) {
    if (error.code === 'LIMIT_FILE_SIZE') {
      return res.status(400).json({
        error: '文件过大（最大 10MB）',
        code: 'FILE_TOO_LARGE'
      });
    }
    return res.status(400).json({
      error: error.message,
      code: 'UPLOAD_ERROR'
    });
  }

  if (error.message === '只支持图片格式') {
    return res.status(400).json({
      error: error.message,
      code: 'INVALID_FILE_TYPE'
    });
  }

  console.error('[clipboard] 未处理的错误:', error);
  res.status(500).json({
    error: '服务器内部错误',
    code: 'INTERNAL_ERROR'
  });
});

// 启动服务器
app.listen(PORT, '127.0.0.1', () => {
  console.log(`[clipboard] 服务已启动，监听端口: ${PORT}`);
  console.log(`[clipboard] 健康检查: http://127.0.0.1:${PORT}/health`);
  console.log(`[clipboard] API 端点: http://127.0.0.1:${PORT}/api/clipboard-image`);
});

// 优雅关闭
process.on('SIGTERM', () => {
  console.log('[clipboard] 收到 SIGTERM 信号，正在关闭...');
  process.exit(0);
});

process.on('SIGINT', () => {
  console.log('[clipboard] 收到 SIGINT 信号，正在关闭...');
  process.exit(0);
});
