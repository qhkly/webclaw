#!/usr/bin/env python3
"""
clipboard-holder.py  <image_path>

使用 python-xlib 直接操作 X11 CLIPBOARD selection，
同时持有 image/png（供 GIMP 等 GUI 应用粘贴图片）
和 UTF8_STRING / text/plain（供终端 Ctrl+V 粘贴文件路径）。

当其他应用取得 clipboard 所有权时自动退出。
"""
import sys, os, signal, threading

from Xlib import X, display as xdisplay, Xatom
from Xlib.protocol import event as xevent


def main():
    if len(sys.argv) < 2:
        sys.exit(1)

    image_path = sys.argv[1]
    with open(image_path, 'rb') as f:
        img_data = f.read()

    path_bytes = image_path.encode('utf-8')

    d = xdisplay.Display()
    screen = d.screen()
    root = screen.root

    # 创建一个不可见窗口作为 clipboard owner
    win = root.create_window(0, 0, 1, 1, 0, X.CopyFromParent)

    # 获取需要的 Atoms
    CLIPBOARD     = d.intern_atom('CLIPBOARD')
    TARGETS       = d.intern_atom('TARGETS')
    IMAGE_PNG     = d.intern_atom('image/png')
    UTF8_STRING   = d.intern_atom('UTF8_STRING')
    TEXT_PLAIN    = d.intern_atom('text/plain')
    TEXT_PLAIN_UTF8 = d.intern_atom('text/plain;charset=utf-8')
    TEXT          = d.intern_atom('TEXT')
    STRING        = Xatom.STRING
    INCR          = d.intern_atom('INCR')

    SUPPORTED_TARGETS = [TARGETS, IMAGE_PNG, UTF8_STRING, TEXT_PLAIN,
                         TEXT_PLAIN_UTF8, TEXT, STRING]

    # 取得 CLIPBOARD selection 所有权
    win.set_selection_owner(CLIPBOARD, X.CurrentTime)
    d.flush()

    # 验证是否成功取得所有权
    owner = d.get_selection_owner(CLIPBOARD)
    if owner != win:
        print('[clipboard-holder] 无法取得 CLIPBOARD 所有权', file=sys.stderr)
        sys.exit(1)

    done = threading.Event()

    def handle_selection_request(ev):
        requestor = ev.requestor
        prop      = ev.property if ev.property != X.NONE else ev.target
        target    = ev.target
        time_     = ev.time

        if target == TARGETS:
            requestor.change_property(prop, Xatom.ATOM, 32,
                                      [t for t in SUPPORTED_TARGETS])
        elif target == IMAGE_PNG:
            # INCR 协议：大数据分块传输（阈值 256KB）
            if len(img_data) > 256 * 1024:
                requestor.change_property(prop, INCR, 32, [len(img_data)])
                send_notify(d, ev, prop)
                # 等待 PropertyNotify(Delete) 后分块发送
                send_incr(d, requestor, prop, IMAGE_PNG, img_data)
                return
            else:
                requestor.change_property(prop, IMAGE_PNG, 8, img_data)
        elif target in (UTF8_STRING, TEXT_PLAIN, TEXT_PLAIN_UTF8):
            requestor.change_property(prop, UTF8_STRING, 8, path_bytes)
        elif target in (TEXT, STRING):
            requestor.change_property(prop, STRING, 8, path_bytes)
        else:
            # 不支持的 target
            prop = X.NONE

        send_notify(d, ev, prop)

    def send_notify(d, ev, prop):
        resp = xevent.SelectionNotify(
            time=ev.time,
            requestor=ev.requestor,
            selection=ev.selection,
            target=ev.target,
            property=prop,
        )
        ev.requestor.send_event(resp)
        d.flush()

    def send_incr(d, requestor, prop, target_atom, data):
        """INCR 协议：逐块发送大数据"""
        CHUNK = 65536
        offset = 0
        # 等待第一次 PropertyDelete（requestor 已读走 INCR 标记）
        wait_property_delete(d, requestor, prop)
        while offset < len(data):
            chunk = data[offset:offset + CHUNK]
            requestor.change_property(prop, target_atom, 8, chunk)
            d.flush()
            offset += len(chunk)
            wait_property_delete(d, requestor, prop)
        # 发送空属性表示结束
        requestor.change_property(prop, target_atom, 8, b'')
        d.flush()

    def wait_property_delete(d, win, prop):
        while True:
            ev = d.next_event()
            if (ev.type == X.PropertyNotify and
                    ev.window == win and
                    ev.atom == prop and
                    ev.state == X.PropertyDelete):
                return

    def event_loop():
        while not done.is_set():
            try:
                if d.pending_events() == 0:
                    # 用 select 等待，避免忙等
                    import select
                    r, _, _ = select.select([d.fileno()], [], [], 0.1)
                    if not r:
                        continue
                ev = d.next_event()
            except Exception:
                break

            if ev.type == X.SelectionRequest:
                if ev.selection == CLIPBOARD:
                    handle_selection_request(ev)
            elif ev.type == X.SelectionClear:
                # 其他应用取得了 CLIPBOARD 所有权，退出
                if ev.selection == CLIPBOARD:
                    done.set()
                    break

    def on_signal(*_):
        done.set()

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    event_loop()
    win.destroy()
    d.close()


if __name__ == '__main__':
    main()
