// Step 0 of window-left-half.
// Resizes the front window of the frontmost app to the left half of the screen it is on,
// leaving out the menu bar and the Dock. Needs Accessibility and the Automation permission
// for System Events.
//
// Coordinates: System Events uses points with the origin at the TOP-left of the primary
// screen, y growing downwards. AppKit (NSScreen) uses the BOTTOM-left of the primary screen,
// y growing upwards. toTopLeft() converts; the primary screen is NSScreen.screens[0].
// Output: what happened, e.g. "Moved Safari's window to the left half of screen 2."
function run(argv) {
    ObjC.import("AppKit");
    const systemEvents = Application("System Events");
    const processes = systemEvents.applicationProcesses.whose({ frontmost: true })();
    if (processes.length === 0) return "No app is frontmost.";
    const frontApp = processes[0];
    const appName = frontApp.name();
    const win = frontWindow(frontApp);
    if (!win) return appName + " has no window to move.";
    if (attribute(win, "AXFullScreen") === true) return appName + "'s window is full screen; leave full screen first.";

    const [x, y] = win.position();
    const [width, height] = win.size();
    const screens = screenList();
    const index = screenIndexFor({ x: x, y: y, width: width, height: height }, screens);
    const target = leftHalf(screens[index].visible);
    // Position, size, then position again: some apps refuse a size that would cross the
    // screen edge from the old position, or move the window while resizing.
    win.position = [target.x, target.y];
    win.size = [target.width, target.height];
    win.position = [target.x, target.y];
    return "Moved " + appName + "'s window to the left half of screen " + (index + 1) + ".";
}

// The main (focused) window, else the first window, else null.
function frontWindow(app) {
    const windows = app.windows();
    for (const win of windows) {
        if (attribute(win, "AXMain") === true) return win;
    }
    return windows.length > 0 ? windows[0] : null;
}

function attribute(element, name) {
    try {
        return element.attributes.byName(name).value();
    } catch (error) {
        return null;
    }
}

// Every screen's full frame and visible frame (without menu bar and Dock), top-left based.
function screenList() {
    const screens = $.NSScreen.screens;
    const primaryHeight = screens.objectAtIndex(0).frame.size.height;
    const result = [];
    for (let i = 0; i < screens.count; i++) {
        const screen = screens.objectAtIndex(i);
        result.push({
            frame: toTopLeft(screen.frame, primaryHeight),
            visible: toTopLeft(screen.visibleFrame, primaryHeight)
        });
    }
    return result;
}

// An AppKit rect (bottom-left origin) as {x, y, width, height} with a top-left origin.
function toTopLeft(rect, primaryHeight) {
    return {
        x: rect.origin.x,
        y: primaryHeight - (rect.origin.y + rect.size.height),
        width: rect.size.width,
        height: rect.size.height
    };
}

// The screen showing most of the window; if none does, the one nearest its top-left corner.
function screenIndexFor(win, screens) {
    let best = 0;
    let bestArea = 0;
    screens.forEach((screen, i) => {
        const f = screen.frame;
        const overlapWidth = Math.min(win.x + win.width, f.x + f.width) - Math.max(win.x, f.x);
        const overlapHeight = Math.min(win.y + win.height, f.y + f.height) - Math.max(win.y, f.y);
        const area = Math.max(0, overlapWidth) * Math.max(0, overlapHeight);
        if (area > bestArea) {
            best = i;
            bestArea = area;
        }
    });
    if (bestArea > 0) return best;
    let nearest = 0;
    let nearestDistance = Infinity;
    screens.forEach((screen, i) => {
        const f = screen.frame;
        const dx = Math.max(f.x - win.x, 0, win.x - (f.x + f.width));
        const dy = Math.max(f.y - win.y, 0, win.y - (f.y + f.height));
        const distance = dx * dx + dy * dy;
        if (distance < nearestDistance) {
            nearest = i;
            nearestDistance = distance;
        }
    });
    return nearest;
}

// The left half of a visible frame, in whole points.
function leftHalf(visible) {
    return {
        x: Math.round(visible.x),
        y: Math.round(visible.y),
        width: Math.floor(visible.width / 2),
        height: Math.floor(visible.height)
    };
}
