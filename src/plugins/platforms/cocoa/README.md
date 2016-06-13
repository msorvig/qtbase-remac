Cocoa Platform Plugin User Guide
=======================================================

The Cocoa platform plugin is the backend that supports Qt on macOS (before OS X).
While the intention is that Qt should work out-of-the box also on this platform,
there are still several platform specifics that we want to account for. In
addition there may at any time be new features in development which are available
via opt-in switches.

None the features or options mentioned here are officially supported, unless also
mentioned in the official documentation. This means that options may be removed
or changed (or not developed further) in future versions of Qt. We will refrain
from making breaking changes in patch releases.

A Quick Behind the Scenes Look
=======================================================

Using the default Qt configuration should not require any knowledge of the Cocoa
platform plugin implementation. On the other hand, such knowledge can be useful
when setting options that control how the platform plugin use the native API.

The main backing class for QWindow is NSView, and there is generally a 1-to-1
correspondance between instances of these classes. In addition, top-level
QWindows have a NSWindow instance.

Configuration Options
=======================================================

The Cocoa platform plugin takes options either as environment variables (QT_MAC_FOO),
or as QWindow properties (_q_mac_foo).

Layer Mode - Enable Core Animation Layers for QWindow.
--------------------------------------------------------

Using Core Animation Layers for Qt improves compositing of mixed raster/OpenGL window
content, at the cost of increased memory usage for layer storage and adding a
compositing step.

    QT_MAC_WANTS_LAYER   Make All QWindows opt-in to layer mode. This switch may gain smartness
                         in how it applies the layer setting - layers may not bring any benefit
                         for some QWindow configurations (including but not limited to a single
                         top-level QWindow with no child QWindows).

                         Defults to "off". May default to "on" in a future release.

    _q_mac_wants_layer   Make a spesific QWindow opt-in to layer mode.

                         Defults to "off".

A QWindow can also be switched into layer mode for external reasons:

    * A parent view enables layer mode. Child windows are generally
      switched into layer mode as well.
    * Use certain NSWindow config options, souch as NSFullSizeContentViewWindowMask

Display Link Updates
--------------------------------------------------------

The Cocoa platform plugin can drive updates via CVDisplayLink. This is exposed to Qt
via the QWindow::requestUpdate() / QEvent::UpdateRequest API.

    QT_MAC_ENABLE_CVDISPLAYLINK     Enables CVDisplayLink for all QWindows

                                    Defaults to "off".
    (per-window API missing)

The native CVDIsplayLink API delivers the update callbacks on a secondary thread.
The current Qt implementation delivers the updates on the GUI thread.

The CVTimeStamp pointers normally provided by the display link callback are
available in the Platform Headers module:

    CVTimeStamp *QCocoaWindowFunctions::displayLinkNowTime(QWindow *window)
    CVTimeStamp *QCocoaWindowFunctions::displayLinkOutputTime(QWindow *window)

These functions return a valid pointer during updates driven by the display
link, and null otherwise. The pointers stay valid for the duration of UpdateRequest
handling.


Misc
--------------------------------------------------------

    QT_MAC_OPENGL_SURFACE_ORDER     In "classic" (non-layer ) mode, OpenGL content can be
                                    ordered either on top of or below raster content. This
                                    option selects which.

                                    1 (above, default) / -1 (below) [see NSOpenGLCPSurfaceOrder]

    QT_MAC_SET_RAISE_PROCESS        Force bring process windows to front on startup.

                                    1 (defualt) / 0

    QT_MAC_WANTS_BEST_RESOLUTION_OPENGL_SURFACE     Enable high-DPI for OpenGL-based windows
    _q_mac_wantsBestResolutionOpenGLSurface         1 (default) / 0
