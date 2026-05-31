#!/usr/bin/env python3
"""
clipboard-holder.py  <image_path>

使用 python-xlib 直接操作 X11 CLIPBOARD selection，
同时持有 image/png（供 GIMP 等 GUI 应用粘贴图片）
和 UTF8_STRING / text/plain（供终端 Ctrl+V 粘贴文件路径）。

当其他应用取得 clipboard 所有权时自动退出。
"""
import sys, signal, select

from Xlib import X, display as xdisplay, Xatom
from Xlib.protocol import event as xevent


def main():
    if len(sys.argv) < 2:
        print('[clipboard-holder] 用法: clipboard-holder.py <image_path>', file=sys.stderr)
        sys.exit(1)

    image_path = sys.argv[1]
    try:
        with open(image_path, 'rb') as f:
            img_data = f.read()
    except OSError as e:
        print(f'[clipboard-holder] 读取图片失败: {e}', file=sys.stderr)
        sys.exit(1)

    print(f'[clipboard-holder] 启动，图片 {len(img_data)} 字节，路径 {image_path}', file=sys.stderr)

    path_bytes = image_path.encode('utf-8')

    d = xdisplay.Display()
    screen = d.screen()
    root = screen.root

    win = root.create_window(0, 0, 1, 1, 0, X.CopyFromParent)

    CLIPBOARD       = d.intern_atom('CLIPBOARD')
    TARGETS         = d.intern_atom('TARGETS')
    IMAGE_PNG       = d.intern_atom('image/png')
    UTF8_STRING     = d.intern_atom('UTF8_STRING')
    TEXT_PLAIN      = d.intern_atom('text/plain')
    TEXT_PLAIN_UTF8 = d.intern_atom('text/plain;charset=utf-8')
    TEXT            = d.intern_atom('TEXT')
    STRING          = Xatom.STRING
    INCR            = d.intern_atom('INCR')

    SUPPORTED_TARGETS = [TARGETS, IMAGE_PNG, UTF8_STRING, TEXT_PLAIN,
                         TEXT_PLAIN_UTF8, TEXT, STRING]

    win.set_selection_owner(CLIPBOARD, X.CurrentTime)
    d.flush()

    owner = d.get_selection_owner(CLIPBOARD)
    if owner != win:
        print('[clipboard-holder] 无法取得 CLIPBOARD 所有权', file=sys.stderr)
        sys.exit(1)

    print('[clipboard-holder] 已取得 CLIPBOARD 所有权', file=sys.stderr)

    running = True

    def handle_selection_request(ev):
        requestor = ev.requestor
        prop      = ev.property if ev.property != X.NONE else ev.target
        target    = ev.target

        if target == TARGETS:
            requestor.change_property(prop, Xatom.ATOM, 32,
                                      [t for t in SUPPORTED_TARGETS])
        elif target == IMAGE_PNG:
            if len(img_data) > 60 * 1024:
                send_incr(ev, prop, IMAGE_PNG, img_data)
                return
            requestor.change_property(prop, IMAGE_PNG, 8, img_data)
        elif target in (UTF8_STRING, TEXT_PLAIN, TEXT_PLAIN_UTF8):
            requestor.change_property(prop, UTF8_STRING, 8, path_bytes)
        elif target in (TEXT, STRING):
            requestor.change_property(prop, STRING, 8, path_bytes)
        else:
            prop = X.NONE

        resp = xevent.SelectionNotify(
            time=ev.time,
            requestor=ev.requestor,
            selection=ev.selection,
            target=ev.target,
            property=prop,
        )
        ev.requestor.send_event(resp)
        d.flush()

    def send_selection_notify(ev, prop):
        resp = xevent.SelectionNotify(
            time=ev.time,
            requestor=ev.requestor,
            selection=ev.selection,
            target=ev.target,
            property=prop,
        )
        ev.requestor.send_event(resp)
        d.flush()

    def wait_property_delete(requestor, prop):
        while True:
            ev = d.next_event()
            if (ev.type == X.PropertyNotify and
                    ev.window == requestor and
                    ev.atom == prop and
                    ev.state == X.PropertyDelete):
                return
            if ev.type == X.SelectionClear and ev.atom == CLIPBOARD:
                raise RuntimeError('lost CLIPBOARD ownership during INCR transfer')

    def send_incr(ev, prop, target_atom, data):
        requestor = ev.requestor
        requestor.change_attributes(event_mask=X.PropertyChangeMask)
        requestor.change_property(prop, INCR, 32, [len(data)])
        send_selection_notify(ev, prop)
        wait_property_delete(requestor, prop)

        chunk_size = 32 * 1024
        for offset in range(0, len(data), chunk_size):
            requestor.change_property(prop, target_atom, 8, data[offset:offset + chunk_size])
            d.flush()
            wait_property_delete(requestor, prop)

        requestor.change_property(prop, target_atom, 8, b'')
        d.flush()

    def on_signal(*_):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    while running:
        try:
            if d.pending_events() == 0:
                r, _, _ = select.select([d.fileno()], [], [], 0.1)
                if not r:
                    continue
            ev = d.next_event()
        except Exception as e:
            print(f'[clipboard-holder] 事件循环异常: {e}', file=sys.stderr)
            break

        if ev.type == X.SelectionRequest:
            if ev.selection == CLIPBOARD:
                handle_selection_request(ev)
        elif ev.type == X.SelectionClear:
            if ev.atom == CLIPBOARD:
                print('[clipboard-holder] 失去 CLIPBOARD 所有权，退出', file=sys.stderr)
                break

    win.destroy()
    d.close()
    print('[clipboard-holder] 已退出', file=sys.stderr)


if __name__ == '__main__':
    main()
