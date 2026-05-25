/*
 * custom-clipboard-image.js
 *
 * Mac↔容器 图片同步：双按钮注入到 noVNC 自带 Clipboard 面板。
 * Mac↔容器 文本同步：复用 noVNC 原生 RFB clipboard 文本通道。
 * 不监听 Ctrl+C —— 容器内 Ctrl+C 和终端中断永不被脚本污染。
 *
 * 按钮 A：把 Mac 剪贴板里的图片粘到容器
 * 按钮 B：把容器剪贴板里的图片拷到 Mac
 *
 * Mac↔容器 文本同步：
 * - 容器复制文本后，自动尝试写入 Mac 系统剪贴板。
 * - Mac 在 noVNC 页面粘贴文本时，写入容器剪贴板并主动粘贴到当前焦点。
 */

(function() {
  'use strict';

  // 轻量 i18n：按浏览器语言选中/英文。zh 系列走中文，其余走英文。
  const I18N = {
    'zh': {
      btn_mac_to_container: '粘贴',
      btn_mac_to_container_title: '自动检测图片或文字，一键粘贴到容器当前焦点',
      btn_container_to_mac: '拷贝',
      btn_container_to_mac_title: '自动检测图片或文字，一键拷贝到本地剪贴板',
      read_mac_failed: '✗ 读取本地剪贴板失败：',
      no_image_in_mac: '本地剪贴板没有图片',
      image_too_large: '图片过大（>10MB）',
      syncing_to_container: '正在同步图片到容器...',
      pasted_to_container: '✓ 已粘到容器',
      sync_failed: '✗ 同步失败：',
      reading_from_container: '正在从容器读取图片...',
      no_image_in_container: '容器剪贴板没有图片',
      copied_to_mac: '✓ 已拷到本地',
      copy_failed: '✗ 拷贝失败：',
      api_unsupported: '浏览器不支持剪贴板 API',
      text_copied_to_mac: '✓ 文字已拷到本地',
      text_clipboard_blocked: '文本已到 noVNC 剪贴板面板，浏览器未授权写入本地剪贴板',
      text_pasted_to_container: '✓ 文字已粘到容器',
      no_content_local: '本地剪贴板没有内容',
      no_content_container: '容器剪贴板没有内容'
    },
    'en': {
      btn_mac_to_container: 'Paste',
      btn_mac_to_container_title: 'Auto-detect image or text, paste to container focus in one click',
      btn_container_to_mac: 'Copy',
      btn_container_to_mac_title: 'Auto-detect image or text, copy to local clipboard in one click',
      read_mac_failed: '✗ Failed to read local clipboard: ',
      no_image_in_mac: 'No image in local clipboard',
      image_too_large: 'Image too large (>10MB)',
      syncing_to_container: 'Syncing image to container...',
      pasted_to_container: '✓ Pasted to container',
      sync_failed: '✗ Sync failed: ',
      reading_from_container: 'Reading image from container...',
      no_image_in_container: 'No image in container clipboard',
      copied_to_mac: '✓ Copied to local',
      copy_failed: '✗ Copy failed: ',
      api_unsupported: 'Browser does not support Clipboard API',
      text_copied_to_mac: '✓ Text copied to local',
      text_clipboard_blocked: 'Text is in the noVNC clipboard panel. Browser permission blocked local clipboard write',
      text_pasted_to_container: '✓ Text pasted to container',
      no_content_local: 'No content in local clipboard',
      no_content_container: 'No content in container clipboard'
    }
  };
  const T = (navigator.language || 'en').toLowerCase().startsWith('zh') ? I18N.zh : I18N.en;
  let lastTextSentToContainer = '';
  let lastTextCopiedToMac = '';
  let lastTextSeenFromContainer = '';

  const loading = document.getElementById('clipboard-loading') || createLoadingElement();

  function createLoadingElement() {
    const div = document.createElement('div');
    div.id = 'clipboard-loading';
    div.style.cssText = `
      position: fixed;
      top: 50%;
      left: 50%;
      transform: translate(-50%, -50%);
      background: rgba(0, 0, 0, 0.8);
      color: white;
      padding: 20px 40px;
      border-radius: 8px;
      font-size: 16px;
      z-index: 9999;
      display: none;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    `;
    document.body.appendChild(div);
    return div;
  }

  function showLoading(message, type = '') {
    loading.textContent = message;
    loading.className = type;
    loading.style.display = 'block';
  }

  function hideLoading() {
    setTimeout(() => {
      loading.style.display = 'none';
    }, 1500);
  }

  // noVNC 挂在 /proxy/10004/ 下 → 走 /proxy/10009/api/clipboard-image
  // 开发直连 → /api/clipboard-image
  function getClipboardApiUrl() {
    const basePath = location.pathname.match(/\/proxy\/10004\//) ? '/proxy/10009/' : '/';
    return location.protocol + '//' + location.host + basePath + 'api/clipboard-image';
  }

  function getClipboardTextApiUrl() {
    const basePath = location.pathname.match(/\/proxy\/10004\//) ? '/proxy/10009/' : '/';
    return location.protocol + '//' + location.host + basePath + 'api/clipboard-text';
  }

  async function uploadImageToServer(blob) {
    const formData = new FormData();
    formData.append('image', blob, 'pasted-image.png');
    const response = await fetch(getClipboardApiUrl(), {
      method: 'POST',
      body: formData
    });
    if (!response.ok) {
      const error = await response.json().catch(() => ({ error: '上传失败' }));
      throw new Error(error.error || '上传失败');
    }
    return await response.json();
  }

  // 通过 RFB 给容器注入 Ctrl+V（完整 Ctrl↓ V↓ V↑ Ctrl↑ 序列）
  function sendCtrlVToContainer() {
    const rfb = (window.UI && window.UI.rfb) || window.rfb;
    if (!rfb || typeof rfb.sendKey !== 'function') {
      throw new Error('noVNC RFB 实例不可用');
    }
    const XK_Control_L = 0xffe3;
    const XK_V = 0x0076;
    rfb.sendKey(XK_Control_L, 'ControlLeft', true);
    rfb.sendKey(XK_V, 'KeyV', true);
    rfb.sendKey(XK_V, 'KeyV', false);
    rfb.sendKey(XK_Control_L, 'ControlLeft', false);
  }

  function getRfb() {
    return (window.UI && window.UI.rfb) || window.rfb || null;
  }

  function isEditableElement(el) {
    if (!el) return false;
    const tag = (el.tagName || '').toLowerCase();
    return tag === 'textarea' || tag === 'input' || el.isContentEditable;
  }

  function setNoVncClipboardText(text) {
    const textarea = document.getElementById('noVNC_clipboard_text');
    if (textarea) {
      textarea.value = text;
    }
  }

  async function writeTextToMacClipboard(text) {
    if (!text || !navigator.clipboard || !navigator.clipboard.writeText) {
      return false;
    }
    try {
      await navigator.clipboard.writeText(text);
      lastTextCopiedToMac = text;
      return true;
    } catch (err) {
      console.warn('[clipboard] text write to Mac clipboard blocked:', err && err.message);
      return false;
    }
  }

  function sendTextToContainerClipboard(text) {
    const rfb = getRfb();
    if (!rfb || typeof rfb.clipboardPasteFrom !== 'function') {
      throw new Error('noVNC RFB 剪贴板不可用');
    }
    lastTextSentToContainer = text;
    setNoVncClipboardText(text);
    rfb.clipboardPasteFrom(text);
  }

  async function writeTextToContainerClipboard(text) {
    const response = await fetch(getClipboardTextApiUrl(), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text })
    });
    if (!response.ok) {
      const error = await response.json().catch(() => ({ error: '写入文本剪贴板失败' }));
      throw new Error(error.error || '写入文本剪贴板失败');
    }
  }

  async function syncTextToContainer(text) {
    try {
      sendTextToContainerClipboard(text);
    } catch (err) {
      console.warn('[clipboard] noVNC text clipboard failed, falling back to xclip:', err && err.message);
      await writeTextToContainerClipboard(text);
      lastTextSentToContainer = text;
      setNoVncClipboardText(text);
    }
  }

  async function pasteTextToContainer(text, source = 'unknown') {
    if (!text || !text.trim()) {
      return false;
    }

    try {
      await syncTextToContainer(text);
      await new Promise(resolve => setTimeout(resolve, 200));
      sendCtrlVToContainer();
      showLoading(T.text_pasted_to_container, 'success');
      hideLoading();
      return true;
    } catch (err) {
      console.warn('[clipboard] Text paste to container failed:', err && err.message);
      showLoading(T.sync_failed + (err.message || ''), 'error');
      hideLoading();
      return false;
    }
  }

  function clearTextarea() {
    const textarea = document.getElementById('noVNC_clipboard_text');
    if (textarea) {
      textarea.value = '';
    }
  }

  function looksLikeBinaryData(text) {
    // Reject PNG/JPEG/other binary that VNC server may forward as clipboard text.
    // Check first 8 chars for control bytes or C1-control-block chars (0x80–0x9F).
    const n = Math.min(text.length, 8);
    for (let i = 0; i < n; i++) {
      const c = text.charCodeAt(i);
      // Allow tab (9), LF (10), CR (13); reject other controls and C1 block
      if ((c < 9) || (c === 11 || c === 12) || (c >= 14 && c < 32) || (c >= 0x80 && c <= 0x9F)) {
        return true;
      }
    }
    return false;
  }

  async function handleRfbClipboard(e) {
    const text = e && e.detail && typeof e.detail.text === 'string' ? e.detail.text : '';
    if (!text || looksLikeBinaryData(text)) return;
    if (text !== lastTextSentToContainer && text !== lastTextCopiedToMac && text !== lastTextSeenFromContainer) {
      lastTextSeenFromContainer = text;
      await syncTextFromContainerToMac(text);
    }
  }

  async function syncTextFromContainerToMac(text) {
    setNoVncClipboardText(text);
    const ok = await writeTextToMacClipboard(text);
    if (!ok) {
      // Browser blocked. Write to X11 CLIPBOARD so the Tauri desktop app's
      // sync loop (polling every 500ms) can relay it to the Mac clipboard.
      try {
        await fetch(getClipboardTextApiUrl(), {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ text })
        });
      } catch (_) {}
      // In Tauri webview: sync happens silently via desktop app, no toast needed.
      // In regular browser: inform user that sync didn't reach Mac clipboard directly.
      if (!window.__TAURI__) {
        showLoading(T.text_clipboard_blocked, 'error');
        hideLoading();
      }
    }
  }

  async function handleBrowserPaste(e) {
    if (isEditableElement(e.target) && e.target.id !== 'noVNC_canvas') {
      return;
    }
    const text = e.clipboardData && e.clipboardData.getData('text/plain');
    if (!text) {
      return;
    }

    try {
      e.preventDefault();
      e.stopPropagation();
      await pasteTextToContainer(text, 'keyboard');
    } catch (err) {
      console.warn('[clipboard] Local text paste to container failed:', err && err.message);
    }
  }

  async function pollContainerTextClipboard() {
    try {
      const resp = await fetch(getClipboardTextApiUrl(), { method: 'GET', cache: 'no-store' });
      if (resp.status === 404) return;
      if (!resp.ok) throw new Error('GET ' + resp.status);
      const data = await resp.json();
      const text = typeof data.text === 'string' ? data.text : '';
      if (!text || text === lastTextSeenFromContainer || text === lastTextSentToContainer || text === lastTextCopiedToMac) {
        return;
      }
      lastTextSeenFromContainer = text;
      await syncTextFromContainerToMac(text);
    } catch (err) {
      console.warn('[clipboard] text clipboard polling failed:', err && err.message);
    }
  }

  function initTextClipboardBridge() {
    if (document.__webclawTextClipboardPasteBridge) {
      return;
    }
    document.__webclawTextClipboardPasteBridge = true;
    document.addEventListener('paste', handleBrowserPaste, true);

    // 监听 Ctrl+V / Ctrl+Shift+V，都从 Mac 剪贴板同步到容器
    let lastCtrlVTime = 0;
    document.addEventListener('keydown', async (e) => {
      const isCmdOrCtrl = e.metaKey || e.ctrlKey;
      const isVKey = e.key === 'v' || e.key === 'V';

      // Ctrl+V 或 Ctrl+Shift+V，都处理
      if (isCmdOrCtrl && isVKey) {
        // 如果焦点在输入元素内，让浏览器正常处理
        if (isEditableElement(e.target)) {
          return; // 不拦截，让浏览器原生粘贴
        }

        const now = Date.now();
        if (now - lastCtrlVTime < 500) {
          e.preventDefault();
          e.stopPropagation();
          return;
        }
        lastCtrlVTime = now;

        // 阻止原始按键，等我们同步完成后再发送对应的按键
        e.preventDefault();
        e.stopPropagation();

        try {
          const text = await navigator.clipboard.readText();
          if (text && text.trim()) {
            const keyName = e.shiftKey ? 'Ctrl+Shift+V' : 'Ctrl+V';
            console.log('[clipboard] ' + keyName + ' detected, syncing Mac clipboard: ' + text.substring(0, 30));

            // 同步到容器剪贴板
            await fetch(getClipboardTextApiUrl(), {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ text })
            });

            lastTextSentToContainer = text;
            console.log('[clipboard] ✓ Synced, sending ' + keyName + ' to container');

            // 等待 xclip 完成，然后手动发送对应的按键到容器
            setTimeout(() => {
              if (e.shiftKey) {
                // 发送 Ctrl+Shift+V
                const rfb = getRfb();
                if (rfb && typeof rfb.sendKey === 'function') {
                  const XK_Control_L = 0xffe3;
                  const XK_Shift_L = 0xffe1;
                  const XK_V = 0x0076;
                  rfb.sendKey(XK_Control_L, 'ControlLeft', true);
                  rfb.sendKey(XK_Shift_L, 'ShiftLeft', true);
                  rfb.sendKey(XK_V, 'KeyV', true);
                  rfb.sendKey(XK_V, 'KeyV', false);
                  rfb.sendKey(XK_Shift_L, 'ShiftLeft', false);
                  rfb.sendKey(XK_Control_L, 'ControlLeft', false);
                }
              } else {
                // 发送 Ctrl+V
                sendCtrlVToContainer();
              }
            }, 100);
          }
        } catch (err) {
          console.warn('[clipboard] Sync failed:', err && err.message);
        }
      }
    }, true);
    let tries = 0;
    const timer = setInterval(() => {
      const rfb = getRfb();
      if (rfb && typeof rfb.addEventListener === 'function') {
        if (!rfb.__webclawTextClipboardBridge) {
          rfb.addEventListener('clipboard', handleRfbClipboard);
          rfb.__webclawTextClipboardBridge = true;
          console.log('[clipboard] 剪贴板监听已启用（文字）');
        }
        clearInterval(timer);
      } else if (++tries >= 50) {
        clearInterval(timer);
        console.warn('[clipboard] RFB 未就绪，文本剪贴板桥未启用');
      }
    }, 200);
  }

  async function readImageFromMacClipboard() {
    if (!navigator.clipboard || !navigator.clipboard.read) {
      throw new Error(T.api_unsupported);
    }
    const items = await navigator.clipboard.read();
    for (const item of items) {
      const imageType = item.types.find(t => t.startsWith('image/'));
      if (imageType) {
        return await item.getType(imageType);
      }
    }
    return null;
  }

  // 按钮 A：本地 → 容器
  async function handleMacToContainer() {
    // 1. 先尝试读取图片
    let imageBlob;
    try {
      imageBlob = await readImageFromMacClipboard();
    } catch (err) {
      console.warn('[clipboard] Image read failed:', err && err.message);
    }

    if (imageBlob) {
      // 现有图片处理流程
      if (imageBlob.size > 10 * 1024 * 1024) {
        showLoading(T.image_too_large, 'error');
        hideLoading();
        return;
      }

      try {
        showLoading(T.syncing_to_container);
        await uploadImageToServer(imageBlob);
        await new Promise(resolve => setTimeout(resolve, 300));
        sendCtrlVToContainer();
        showLoading(T.pasted_to_container, 'success');
        hideLoading();
        clearTextarea();
      } catch (err) {
        console.warn('[clipboard] Local→container image sync failed:', err && err.message);
        showLoading(T.sync_failed + (err.message || ''), 'error');
        hideLoading();
      }
      return;
    }

    // 2. 没有图片，尝试读取文字
    try {
      const text = await navigator.clipboard.readText();
      if (text && text.trim()) {
        const ok = await pasteTextToContainer(text, 'button');
        if (!ok) {
          showLoading(T.sync_failed, 'error');
          hideLoading();
        }
        return;
      }
    } catch (err) {
      console.warn('[clipboard] Text read failed:', err && err.message);
    }

    // 3. 既没有图片也没有文字
    showLoading(T.no_content_local, 'error');
    hideLoading();
  }

  // 按钮 B：容器 → 本地
  async function handleContainerToMac() {
    // 1. 优先：检查容器剪贴板是否有图片
    try {
      const resp = await fetch(getClipboardApiUrl(), { method: 'GET' });
      if (resp.ok) {
        const blob = await resp.blob();
        if (blob && blob.size > 0) {
          await navigator.clipboard.write([new ClipboardItem({ 'image/png': blob })]);
          showLoading(T.copied_to_mac, 'success');
          hideLoading();
          return;
        }
      }
    } catch (err) {
      console.warn('[clipboard] 检查容器图片失败:', err && err.message);
    }

    // 2. 次优先：检查容器剪贴板是否有文字
    try {
      const textResp = await fetch(getClipboardTextApiUrl(), { method: 'GET' });
      if (textResp.ok) {
        const data = await textResp.json();
        const text = data.text;
        if (text && text.trim()) {
          await navigator.clipboard.writeText(text);
          showLoading(T.text_copied_to_mac, 'success');
          hideLoading();
          return;
        }
      }
    } catch (err) {
      console.warn('[clipboard] 检查容器文字失败:', err && err.message);
    }

    // 3. fallback：容器剪贴板为空，检查输入框是否有文字
    const textarea = document.getElementById('noVNC_clipboard_text');
    if (textarea && textarea.value && textarea.value.trim()) {
      try {
        await navigator.clipboard.writeText(textarea.value);
        showLoading(T.text_copied_to_mac, 'success');
        hideLoading();
        return;
      } catch (err) {
        console.warn('[clipboard] 拷贝输入框文字失败:', err && err.message);
      }
    }

    // 4. 都没有内容
    showLoading(T.no_content_container, 'error');
    hideLoading();
  }

  function makeButton(text, title, onClick, isClose = false) {
    const btn = document.createElement('button');
    btn.title = title;

    // 创建文字
    const textSpan = document.createElement('span');
    textSpan.textContent = text;

    btn.appendChild(textSpan);

    btn.style.cssText = `
      ${isClose ? `
        flex-shrink: 0;
        width: 24px;
        height: 24px;
        padding: 0;
        font-size: 18px;
        line-height: 24px;
      ` : `
        flex: 1;
        min-width: 0;
      `}
      margin-top: 0;
      padding: ${isClose ? '0' : '8px 12px'};
      background: ${isClose ? 'transparent' : 'rgba(0, 120, 215, 0.85)'};
      color: ${isClose ? '#999' : 'white'};
      border: ${isClose ? 'none' : 'none'};
      border-radius: 4px;
      font-size: ${isClose ? '18px' : '13px'};
      cursor: pointer;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      user-select: none;
      display: flex;
      align-items: center;
      justify-content: center;
    `;

    if (!isClose) {
      btn.addEventListener('mouseenter', () => {
        btn.style.background = 'rgba(0, 120, 215, 1)';
      });
      btn.addEventListener('mouseleave', () => {
        btn.style.background = 'rgba(0, 120, 215, 0.85)';
      });
    } else {
      btn.addEventListener('mouseenter', () => {
        btn.style.color = '#666';
      });
      btn.addEventListener('mouseleave', () => {
        btn.style.color = '#999';
      });
    }

    btn.addEventListener('click', onClick);
    return btn;
  }

  function toggleClipboardContent() {
    // 找到左侧的剪贴板按钮并触发点击
    const clipboardButton = document.getElementById('noVNC_clipboard_button');
    if (clipboardButton) {
      clipboardButton.click();
    }
  }

  function injectButtons() {
    const panel = document.getElementById('noVNC_clipboard');
    if (!panel) {
      console.warn('[clipboard] #noVNC_clipboard 面板未找到，按钮未注入');
      return false;
    }
    if (panel.querySelector('.custom-clipboard-buttons')) {
      return true;
    }

    const wrap = document.createElement('div');
    wrap.className = 'custom-clipboard-buttons';
    wrap.style.cssText = 'display: flex; gap: 6px; align-items: center; margin-top: 6px;';

    // 粘贴按钮
    const pasteBtn = makeButton(
      T.btn_mac_to_container,
      T.btn_mac_to_container_title,
      handleMacToContainer
    );
    wrap.appendChild(pasteBtn);

    // 拷贝按钮
    const copyBtn = makeButton(
      T.btn_container_to_mac,
      T.btn_container_to_mac_title,
      handleContainerToMac
    );
    wrap.appendChild(copyBtn);

    // 收起/展开按钮
    wrap.appendChild(makeButton(
      '◀',
      '收起/展开面板内容',
      toggleClipboardContent,
      true  // isClose = true
    ));

    panel.appendChild(wrap);
    return true;
  }

  async function checkClipboardSupport() {
    // 检查剪贴板 API 是否真的可用
    if (!navigator.clipboard) {
      return { supported: false };
    }

    const isLocalhost = location.hostname === 'localhost' || location.hostname === '127.0.0.1';
    const isHttps = location.protocol === 'https:';

    if (!isLocalhost && !isHttps) {
      return { supported: false };
    }

    // 检查基本 API 方法是否存在
    if (typeof navigator.clipboard.readText !== 'function' ||
        typeof navigator.clipboard.writeText !== 'function') {
      return { supported: false };
    }

    return { supported: true };
  }

  async function init() {
    console.log('[clipboard] 初始化 Mac↔容器 剪贴板同步');

    // 先检测剪贴板 API 是否可用
    const check = await checkClipboardSupport();
    if (!check.supported) {
      const protocol = location.protocol;
      const host = location.hostname;
      console.warn('[clipboard] ⚠️ 剪贴板 API 不可用，需要 HTTPS 或 localhost 访问', `当前访问: ${protocol}//${host}`);
      return; // 静默失败，不初始化功能
    }

    console.log('[clipboard] ✓ 剪贴板 API 可用');

    // 1. 初始化剪贴板监听（包含 clipboard 事件监听）
    initTextClipboardBridge();

    // 2. 注入按钮
    // noVNC 的 #noVNC_clipboard 是 vnc.html 静态 DOM，DOMContentLoaded 后即可拿到。
    // 但脚本以 defer/end-of-body 形式加载，部分时序下 panel 可能晚到，做一次小重试。
    if (injectButtons()) {
      console.log('[clipboard] 已就绪，按钮注入到 noVNC Clipboard 面板');
      return;
    }
    let tries = 0;
    const timer = setInterval(() => {
      if (injectButtons() || ++tries >= 30) {
        clearInterval(timer);
      }
    }, 200);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

})();
