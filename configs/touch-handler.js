/**
 * touch-handler.js - trackpad-mode touch input for noVNC
 *
 * On touch devices, replaces the default absolute-coordinate touch mapping
 * with a trackpad-style relative-motion model:
 *   - Finger movement generates deltas that move a virtual cursor
 *   - Cursor position is fully decoupled from finger position
 *   - Speed scaling: faster swipes move the cursor further
 *   - Floating SVG cursor shows current mouse position
 *
 * Gesture map:
 *   Single tap (< 200ms, < 8px)          → left click
 *   Double tap (< 300ms gap, near)        → double click
 *   Long press (> 500ms, < 8px)           → right click
 *   Two-finger tap                        → right click
 *   Single finger drag                    → cursor move
 *   Long-press then drag                  → left-button drag
 *   Two-finger vertical swipe             → scroll wheel
 *
 * A physical mouse still works while trackpad mode is active: mouse/wheel events
 * are forwarded through the capture overlay to noVNC's canvas.
 *
 * URL parameters:
 *   ?touch=1  force-enable trackpad mode (e.g. touchscreen laptops)
 *   ?touch=0  force-disable (overlay not installed; native mouse + touch only)
 */
(function () {
  'use strict';

  console.log('[touch-handler] Script loaded');
  console.log('[touch-handler] ontouchstart:', 'ontouchstart' in window);
  console.log('[touch-handler] maxTouchPoints:', navigator.maxTouchPoints);
  console.log('[touch-handler] userAgent:', navigator.userAgent);

  // URL parameter control:
  //   ?touch=1 → force-enable trackpad mode (debugging / touchscreen laptops)
  //   ?touch=0 → force-disable; the overlay is never installed, so noVNC keeps
  //              its native mouse + touch handling (use on touchscreen PCs that
  //              only want a plain mouse)
  // Otherwise auto-activate on any touch-capable device. Because the overlay now
  // forwards mouse events to the canvas (see init()), enabling trackpad mode on a
  // hybrid touch+mouse computer no longer breaks the mouse — both work together.
  var forceTouch = /(?:^|[?&])touch=1(?:&|$)/.test(location.search);
  var disableTouch = /(?:^|[?&])touch=0(?:&|$)/.test(location.search);
  var hasTouch = 'ontouchstart' in window || navigator.maxTouchPoints > 0;
  if (disableTouch) {
    console.log('[touch-handler] touch=0 in URL, trackpad mode disabled');
    return;
  }
  if (!hasTouch && !forceTouch) {
    console.log('[touch-handler] No touch detected, skipping initialization');
    return;
  }
  console.log('[touch-handler] Touch detected or forced, initializing...');

  // ── Constants ─────────────────────────────────────────────
  var TAP_DURATION   = 200;   // ms — max duration for a tap
  var TAP_DISTANCE   = 8;     // px — max movement for a tap
  var DOUBLE_TAP_GAP = 300;   // ms — max gap between two taps
  var LONG_PRESS_MS  = 500;   // ms — long press threshold
  var SPEED_FACTOR   = 0.4;   // velocity scale coefficient
  var EDGE_THRESHOLD = 0;     // px — cursor can reach true edge (0 or viewport.w/h)
  var EDGE_SCROLL_SPEED = 2.0; // px/frame per overflow px (faster)
  var MAX_SCROLL_SPEED = 30;  // px/frame maximum scroll speed (faster)

  // ── State ─────────────────────────────────────────────────
  var canvas = null;
  var overlay = null;
  var cursor = null;

  var virtualX = 0;
  var virtualY = 0;

  var lastTouchX = 0;
  var lastTouchY = 0;
  var lastTouchTime = 0;

  var touchStartX = 0;
  var touchStartY = 0;
  var touchStartTime = 0;

  var longPressTimer = null;
  var longPressTriggered = false;
  var buttonDown = false;

  var lastTapTime = 0;
  var lastTapX = 0;
  var lastTapY = 0;

  // Two-finger scroll state
  var prevTwoFingerY = null;

  // ── Virtual cursor DOM ────────────────────────────────────
  function createCursor() {
    var el = document.createElement('div');
    el.id = 'touch-cursor';
    el.style.cssText = [
      'position:fixed',
      'pointer-events:none',
      'z-index:10000',
      'width:20px',
      'height:24px',
      'display:none',
      'transform:translate(-2px,-2px)',
    ].join(';');
    el.innerHTML =
      '<svg width="20" height="24" xmlns="http://www.w3.org/2000/svg">' +
      '<polygon points="2,2 2,20 7,15 11,22 13,21 9,14 16,14" ' +
      'fill="white" stroke="black" stroke-width="1.5" stroke-linejoin="round"/>' +
      '</svg>';
    document.body.appendChild(el);
    return el;
  }

  function updateCursorPos() {
    if (!cursor || !canvas) return;
    var rect = canvas.getBoundingClientRect();
    cursor.style.left = (rect.left + virtualX) + 'px';
    cursor.style.top  = (rect.top  + virtualY) + 'px';
    cursor.style.display = 'block';
  }

  // ── Clamp helper ─────────────────────────────────────────
  function clamp(v, lo, hi) {
    return v < lo ? lo : v > hi ? hi : v;
  }

  // ── Get canvas-relative client position for current virtual coords ──
  function getClientPos() {
    var rect = canvas.getBoundingClientRect();
    return {
      x: rect.left + virtualX,
      y: rect.top  + virtualY
    };
  }

  // ── Synthetic event helpers ───────────────────────────────
  function sendMouse(type, button, buttons) {
    var p = getClientPos();
    canvas.dispatchEvent(new MouseEvent(type, {
      bubbles:    true,
      cancelable: true,
      view:       window,
      clientX:    p.x,
      clientY:    p.y,
      button:     button  || 0,
      buttons:    buttons || 0
    }));
  }

  function sendWheel(deltaY) {
    var p = getClientPos();
    canvas.dispatchEvent(new WheelEvent('wheel', {
      bubbles:    true,
      cancelable: true,
      view:       window,
      clientX:    p.x,
      clientY:    p.y,
      deltaY:     deltaY,
      deltaMode:  0
    }));
  }

  // ── Mouse pass-through ────────────────────────────────────
  // The overlay sits on top of the canvas to capture touch, but it would
  // otherwise swallow real mouse input (no mouse handlers → clicks/moves never
  // reach noVNC). Forward genuine mouse/wheel events to the canvas at their real
  // coordinates so noVNC handles them natively (absolute positioning).
  function forwardMouse(e) {
    e.stopPropagation();
    // preventDefault stops the overlay from stealing/clearing the canvas's
    // keyboard focus on mousedown — otherwise typing breaks after a click.
    e.preventDefault();
    // Hide the touch trackpad cursor while a physical mouse is in use
    if (cursor) cursor.style.display = 'none';
    canvas.dispatchEvent(new MouseEvent(e.type, {
      bubbles:    true,
      cancelable: true,
      view:       window,
      clientX:    e.clientX,
      clientY:    e.clientY,
      button:     e.button,
      buttons:    e.buttons
    }));
    // Keep keyboard focus on the canvas so typing works after clicking
    if (e.type === 'mousedown' && canvas.focus) canvas.focus();
  }

  function forwardWheel(e) {
    e.stopPropagation();
    e.preventDefault();
    canvas.dispatchEvent(new WheelEvent('wheel', {
      bubbles:    true,
      cancelable: true,
      view:       window,
      clientX:    e.clientX,
      clientY:    e.clientY,
      deltaX:     e.deltaX,
      deltaY:     e.deltaY,
      deltaMode:  e.deltaMode
    }));
  }

  // ── Long press cancel ─────────────────────────────────────
  function cancelLongPress() {
    if (longPressTimer) {
      clearTimeout(longPressTimer);
      longPressTimer = null;
    }
  }

  // ── Get noVNC Display instance for viewport control ────────
  function getDisplay() {
    // Method 1: Try window.UI_imported from dynamic import
    if (window.UI_imported && UI_imported.rfb) {
      if (UI_imported.rfb._display) {
        return UI_imported.rfb._display;
      }
      if (UI_imported.rfb.display) {
        return UI_imported.rfb.display;
      }
    }

    // Method 2: Check canvas._rfb._display (RFB attaches itself to target element)
    if (canvas && canvas._rfb) {
      if (canvas._rfb._display) {
        return canvas._rfb._display;
      }
      if (canvas._rfb.display) {
        return canvas._rfb.display;
      }
    }

    // Method 3: Try to find RFB on container
    var container = document.getElementById('noVNC_container');
    if (container && container._rfb) {
      if (container._rfb._display) {
        return container._rfb._display;
      }
      if (container._rfb.display) {
        return container._rfb.display;
      }
    }

    return null;
  }

  // ── Edge auto-scroll when cursor reaches viewport edges ─────
  function handleEdgeScroll() {
    var display = getDisplay();
    if (!display) {
      // Silently skip if display not ready yet (dynamic import pending)
      return;
    }

    var viewport = display._viewportLoc;
    if (!viewport) {
      console.log('[edge-scroll] No viewport on display');
      return;
    }

    var scrollX = 0, scrollY = 0;
    var cursorUpdated = false;

    // Right edge: cursor went past viewport width
    if (virtualX > viewport.w) {
      var overflow = virtualX - viewport.w;
      scrollX = Math.min(overflow * EDGE_SCROLL_SPEED, MAX_SCROLL_SPEED);
      virtualX = viewport.w; // Clamp to edge
      cursorUpdated = true;
    }
    // Left edge: cursor went past 0
    else if (virtualX < 0) {
      var overflow = -virtualX;
      scrollX = -Math.min(overflow * EDGE_SCROLL_SPEED, MAX_SCROLL_SPEED);
      virtualX = 0; // Clamp to edge
      cursorUpdated = true;
    }

    // Bottom edge: cursor went past viewport height
    if (virtualY > viewport.h) {
      var overflow = virtualY - viewport.h;
      scrollY = Math.min(overflow * EDGE_SCROLL_SPEED, MAX_SCROLL_SPEED);
      virtualY = viewport.h; // Clamp to edge
      cursorUpdated = true;
    }
    // Top edge: cursor went past 0
    else if (virtualY < 0) {
      var overflow = -virtualY;
      scrollY = -Math.min(overflow * EDGE_SCROLL_SPEED, MAX_SCROLL_SPEED);
      virtualY = 0; // Clamp to edge
      cursorUpdated = true;
    }

    // Apply scrolling if needed
    if (scrollX !== 0 || scrollY !== 0) {
      console.log('[edge-scroll] Scrolling:', scrollX.toFixed(1), scrollY.toFixed(1));
      display.viewportChangePos(scrollX, scrollY);
      updateCursorPos();
    }
  }

  // ── Touch event handlers ──────────────────────────────────
  function onTouchStart(e) {
    console.log('[touch-handler] touchstart, touches:', e.touches.length);
    e.preventDefault();
    e.stopPropagation();

    var touches = e.touches;

    if (touches.length === 1) {
      var t = touches[0];
      touchStartX   = t.clientX;
      touchStartY   = t.clientY;
      touchStartTime = Date.now();

      lastTouchX    = t.clientX;
      lastTouchY    = t.clientY;
      lastTouchTime = touchStartTime;

      longPressTriggered = false;
      buttonDown = false;

      // Start long-press timer
      longPressTimer = setTimeout(function () {
        longPressTimer = null;
        var dx = Math.abs(lastTouchX - touchStartX);
        var dy = Math.abs(lastTouchY - touchStartY);
        if (dx < TAP_DISTANCE && dy < TAP_DISTANCE) {
          longPressTriggered = true;
          // Vibrate as feedback if supported
          if (navigator.vibrate) navigator.vibrate(30);
          // Begin left-button drag
          sendMouse('mousedown', 0, 1);
          buttonDown = true;
        }
      }, LONG_PRESS_MS);

    } else if (touches.length === 2) {
      // Two fingers — cancel single-finger long press
      cancelLongPress();
      if (buttonDown) {
        sendMouse('mouseup', 0, 0);
        buttonDown = false;
      }
      // Record initial midpoint Y for scroll
      prevTwoFingerY = (touches[0].clientY + touches[1].clientY) / 2;
    }
  }

  function onTouchMove(e) {
    e.preventDefault();
    e.stopPropagation();

    var touches = e.touches;

    if (touches.length === 1) {
      var t = touches[0];
      var now = Date.now();

      var dx = t.clientX - lastTouchX;
      var dy = t.clientY - lastTouchY;
      var dt = now - lastTouchTime;

      // Cancel long press if finger moved significantly
      var totalDx = Math.abs(t.clientX - touchStartX);
      var totalDy = Math.abs(t.clientY - touchStartY);
      if ((totalDx > TAP_DISTANCE || totalDy > TAP_DISTANCE) && !longPressTriggered) {
        cancelLongPress();
      }

      // Speed-scaled delta (Guacamole algorithm)
      var velocity = dt > 0 ? (Math.abs(dx) + Math.abs(dy)) / dt : 0;
      var scale = 1 + velocity * SPEED_FACTOR;

      // Allow cursor to move beyond viewport bounds for edge scrolling
      virtualX = virtualX + dx * scale;
      virtualY = virtualY + dy * scale;
      // Note: No clamp - cursor can go outside viewport to trigger edge scroll

      lastTouchX    = t.clientX;
      lastTouchY    = t.clientY;
      lastTouchTime = now;

      updateCursorPos();

      // Edge auto-scroll when cursor reaches viewport boundaries
      handleEdgeScroll();

      if (buttonDown) {
        // Drag mode: send mousemove with button held
        sendMouse('mousemove', 0, 1);
      } else {
        sendMouse('mousemove', 0, 0);
      }

    } else if (touches.length === 2) {
      // Two-finger scroll
      var midY = (touches[0].clientY + touches[1].clientY) / 2;
      if (prevTwoFingerY !== null) {
        var scrollDelta = (prevTwoFingerY - midY) * 3;
        if (Math.abs(scrollDelta) > 0.5) {
          sendWheel(scrollDelta);
        }
      }
      prevTwoFingerY = midY;
    }
  }

  function onTouchEnd(e) {
    e.preventDefault();
    e.stopPropagation();

    var changedTouches = e.changedTouches;
    var remainingTouches = e.touches;

    cancelLongPress();

    // Release drag
    if (buttonDown) {
      sendMouse('mouseup', 0, 0);
      buttonDown = false;
      longPressTriggered = false;
      prevTwoFingerY = null;
      return;
    }

    // Two-finger tap → right click
    if (remainingTouches.length === 0 && changedTouches.length === 2) {
      var t0 = changedTouches[0];
      var t1 = changedTouches[1];
      var d0x = Math.abs(t0.clientX - touchStartX);
      var d0y = Math.abs(t0.clientY - touchStartY);
      var d1x = Math.abs(t1.clientX - touchStartX);
      var d1y = Math.abs(t1.clientY - touchStartY);
      if (d0x < TAP_DISTANCE * 2 && d0y < TAP_DISTANCE * 2 &&
          d1x < TAP_DISTANCE * 2 && d1y < TAP_DISTANCE * 2) {
        sendMouse('mousedown', 2, 2);
        sendMouse('mouseup',   2, 0);
        sendMouse('contextmenu', 2, 0);
      }
      prevTwoFingerY = null;
      return;
    }

    prevTwoFingerY = null;

    // Single-finger tap check
    if (changedTouches.length !== 1 || longPressTriggered) return;

    var t = changedTouches[0];
    var duration = Date.now() - touchStartTime;
    var moveDx = Math.abs(t.clientX - touchStartX);
    var moveDy = Math.abs(t.clientY - touchStartY);

    if (duration < TAP_DURATION && moveDx < TAP_DISTANCE && moveDy < TAP_DISTANCE) {
      var now = Date.now();
      var gapSinceLastTap = now - lastTapTime;
      var tapDx = Math.abs(virtualX - lastTapX);
      var tapDy = Math.abs(virtualY - lastTapY);

      if (gapSinceLastTap < DOUBLE_TAP_GAP && tapDx < TAP_DISTANCE * 3 && tapDy < TAP_DISTANCE * 3) {
        // Double tap → double click
        sendMouse('mousedown', 0, 1);
        sendMouse('mouseup',   0, 0);
        sendMouse('click',     0, 0);
        sendMouse('mousedown', 0, 1);
        sendMouse('mouseup',   0, 0);
        sendMouse('dblclick',  0, 0);
        lastTapTime = 0; // reset so triple-tap doesn't trigger again
      } else {
        // Single tap → left click
        sendMouse('mousedown', 0, 1);
        sendMouse('mouseup',   0, 0);
        sendMouse('click',     0, 0);
        lastTapTime = now;
        lastTapX = virtualX;
        lastTapY = virtualY;
      }
    }
  }

  function onTouchCancel(e) {
    e.preventDefault();
    cancelLongPress();
    if (buttonDown) {
      sendMouse('mouseup', 0, 0);
      buttonDown = false;
    }
    prevTwoFingerY = null;
  }

  // ── Initialise once canvas is available ──────────────────
  function init() {
    console.log('[touch-handler] init() called');
    // noVNC creates canvas dynamically without an ID, so we query it
    canvas = document.querySelector('#noVNC_container canvas');
    if (!canvas) {
      console.log('[touch-handler] Canvas not found yet');
      return false;
    }
    console.log('[touch-handler] Canvas found:', canvas);

    // Position virtual cursor at canvas centre
    var rect = canvas.getBoundingClientRect();
    console.log('[touch-handler] Canvas rect:', rect);
    virtualX = rect.width  / 2;
    virtualY = rect.height / 2;

    cursor = createCursor();
    console.log('[touch-handler] Cursor created:', cursor);
    updateCursorPos();

    // Overlay sits above the canvas, intercepts all touch events
    overlay = document.createElement('div');
    overlay.id = 'touch-overlay';
    overlay.style.cssText = [
      'position:absolute',
      'inset:0',
      'z-index:5',
      'touch-action:none',
    ].join(';');

    var container = canvas.parentElement || document.body;
    console.log('[touch-handler] Container:', container);
    container.style.position = 'relative';
    container.appendChild(overlay);
    console.log('[touch-handler] Overlay appended to container');

    overlay.addEventListener('touchstart',  onTouchStart,  {passive: false});
    overlay.addEventListener('touchmove',   onTouchMove,   {passive: false});
    overlay.addEventListener('touchend',    onTouchEnd,    {passive: false});
    overlay.addEventListener('touchcancel', onTouchCancel, {passive: false});

    // Forward physical mouse input through the overlay to noVNC's canvas so the
    // mouse keeps working on touchscreen computers (hybrid touch + mouse).
    ['mousedown', 'mousemove', 'mouseup', 'click', 'dblclick', 'contextmenu'].forEach(function (type) {
      overlay.addEventListener(type, forwardMouse);
    });
    overlay.addEventListener('wheel', forwardWheel, {passive: false});

    // Start dynamic import of UI module to enable edge scrolling
    console.log('[touch-handler] Starting UI module import...');
    import('./app/ui.js').then(function(module) {
      console.log('[touch-handler] ✓ UI imported, rfb:', !!module.default.rfb);
      window.UI_imported = module.default;
    }).catch(function(e) {
      console.log('[touch-handler] ❌ UI import failed:', e.message);
    });

    console.log('[touch-handler] ✅ Trackpad mode active');
    return true;
  }

  function tryInit() {
    if (!init()) {
      setTimeout(tryInit, 200);
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () { setTimeout(tryInit, 200); });
  } else {
    setTimeout(tryInit, 200);
  }
})();
