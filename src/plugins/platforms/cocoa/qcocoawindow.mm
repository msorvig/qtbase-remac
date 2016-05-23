/****************************************************************************
**
** Copyright (C) 2016 The Qt Company Ltd.
** Contact: https://www.qt.io/licensing/
**
** This file is part of the plugins of the Qt Toolkit.
**
** $QT_BEGIN_LICENSE:LGPL$
** Commercial License Usage
** Licensees holding valid commercial Qt licenses may use this file in
** accordance with the commercial license agreement provided with the
** Software or, alternatively, in accordance with the terms contained in
** a written agreement between you and The Qt Company. For licensing terms
** and conditions see https://www.qt.io/terms-conditions. For further
** information use the contact form at https://www.qt.io/contact-us.
**
** GNU Lesser General Public License Usage
** Alternatively, this file may be used under the terms of the GNU Lesser
** General Public License version 3 as published by the Free Software
** Foundation and appearing in the file LICENSE.LGPL3 included in the
** packaging of this file. Please review the following information to
** ensure the GNU Lesser General Public License version 3 requirements
** will be met: https://www.gnu.org/licenses/lgpl-3.0.html.
**
** GNU General Public License Usage
** Alternatively, this file may be used under the terms of the GNU
** General Public License version 2.0 or (at your option) the GNU General
** Public license version 3 or any later version approved by the KDE Free
** Qt Foundation. The licenses are as published by the Free Software
** Foundation and appearing in the file LICENSE.GPL2 and LICENSE.GPL3
** included in the packaging of this file. Please review the following
** information to ensure the GNU General Public License requirements will
** be met: https://www.gnu.org/licenses/gpl-2.0.html and
** https://www.gnu.org/licenses/gpl-3.0.html.
**
** $QT_END_LICENSE$
**
****************************************************************************/
#include "qcocoawindow.h"
#include "qcocoaintegration.h"
#include "qnswindowdelegate.h"
#include "qcocoaeventdispatcher.h"
#ifndef QT_NO_OPENGL
#include "qcocoaglcontext.h"
#include "qcocoagllayer.h"
#endif
#include "qcocoahelpers.h"
#include "qcocoanativeinterface.h"
#include "qnsview.h"
#include <QtCore/qfileinfo.h>
#include <QtCore/private/qcore_mac_p.h>
#include <qwindow.h>
#include <private/qwindow_p.h>
#include <qpa/qwindowsysteminterface.h>
#include <qpa/qplatformscreen.h>

#include <AppKit/AppKit.h>

#include <QDebug>

enum {
    defaultWindowWidth = 160,
    defaultWindowHeight = 160
};

static bool isMouseEvent(NSEvent *ev)
{
    switch ([ev type]) {
    case NSLeftMouseDown:
    case NSLeftMouseUp:
    case NSRightMouseDown:
    case NSRightMouseUp:
    case NSMouseMoved:
    case NSLeftMouseDragged:
    case NSRightMouseDragged:
        return true;
    default:
        return false;
    }
}

@implementation QNSWindowHelper

@synthesize window = _window;
@synthesize platformWindow = _platformWindow;
@synthesize grabbingMouse = _grabbingMouse;
@synthesize releaseOnMouseUp = _releaseOnMouseUp;

- (id)initWithNSWindow:(QCocoaNSWindow *)window platformWindow:(QCocoaWindow *)platformWindow
{
    self = [super init];
    if (self) {
        _window = window;
        _platformWindow = platformWindow;

        _window.delegate = [[QNSWindowDelegate alloc] initWithQCocoaWindow:_platformWindow];

        // Prevent Cocoa from releasing the window on close. Qt
        // handles the close event asynchronously and we want to
        // make sure that m_nsWindow stays valid until the
        // QCocoaWindow is deleted by Qt.
        [_window setReleasedWhenClosed:NO];
        _watcher = &_platformWindow->sentinel;
    }

    return self;
}

- (void)handleWindowEvent:(NSEvent *)theEvent
{
    QCocoaWindow *pw = self.platformWindow;
    if (_watcher && pw && pw->m_forwardWindow) {
        if (theEvent.type == NSLeftMouseUp || theEvent.type == NSLeftMouseDragged) {
            QNSView *forwardView = pw->qtView();
            if (theEvent.type == NSLeftMouseUp) {
                [forwardView mouseUp:theEvent];
                pw->m_forwardWindow = 0;
            } else {
                [forwardView mouseDragged:theEvent];
            }
        }

        if (!pw->m_isNSWindowChild && theEvent.type == NSLeftMouseDown) {
            pw->m_forwardWindow = 0;
        }
    }

    if (theEvent.type == NSLeftMouseDown) {
        self.grabbingMouse = YES;
    } else if (theEvent.type == NSLeftMouseUp) {
        self.grabbingMouse = NO;
        if (self.releaseOnMouseUp) {
            [self detachFromPlatformWindow];
            [self.window release];
            return;
        }
    }

    // The call to -[NSWindow sendEvent] may result in the window being deleted
    // (e.g., when closing the window by pressing the title bar close button).
    [self retain];
    [self.window superSendEvent:theEvent];
    bool windowStillAlive = self.window != nil; // We need to read before releasing
    [self release];
    if (!windowStillAlive)
        return;

    if (!self.window.delegate)
        return; // Already detached, pending NSAppKitDefined event

    if (_watcher && pw && pw->frameStrutEventsEnabled() && isMouseEvent(theEvent)) {
        NSPoint loc = [theEvent locationInWindow];
        NSRect windowFrame = [self.window convertRectFromScreen:[self.window frame]];
        NSRect contentFrame = [[self.window contentView] frame];
        if (NSMouseInRect(loc, windowFrame, NO) &&
            !NSMouseInRect(loc, contentFrame, NO))
        {
            QNSView *contentView = (QNSView *)pw->contentView();
            [contentView handleFrameStrutMouseEvent: theEvent];
        }
    }
}

- (void)detachFromPlatformWindow
{
    _platformWindow = 0;
    _watcher.clear();
    [self.window.delegate release];
    self.window.delegate = nil;
}

- (void)clearWindow
{
    if (_window) {
        QCocoaEventDispatcher *cocoaEventDispatcher = qobject_cast<QCocoaEventDispatcher *>(QGuiApplication::instance()->eventDispatcher());
        if (cocoaEventDispatcher) {
            QCocoaEventDispatcherPrivate *cocoaEventDispatcherPrivate = static_cast<QCocoaEventDispatcherPrivate *>(QObjectPrivate::get(cocoaEventDispatcher));
            cocoaEventDispatcherPrivate->removeQueuedUserInputEvents([_window windowNumber]);
        }

        _window = nil;
    }
}

- (void)dealloc
{
    _window = nil;
    _platformWindow = 0;
    [super dealloc];
}

@end

@implementation QNSWindow

@synthesize helper = _helper;

- (id)initWithContentRect:(NSRect)contentRect
      styleMask:(NSUInteger)windowStyle
      qPlatformWindow:(QCocoaWindow *)qpw
{
    self = [super initWithContentRect:contentRect
            styleMask:windowStyle
            backing:NSBackingStoreBuffered
            defer:NO]; // Deferring window creation breaks OpenGL (the GL context is
                       // set up before the window is shown and needs a proper window)

    if (self) {
        _helper = [[QNSWindowHelper alloc] initWithNSWindow:self platformWindow:qpw];
    }
    return self;
}

- (BOOL)canBecomeKeyWindow
{
    // Prevent child NSWindows from becoming the key window in
    // order keep the active apperance of the top-level window.
    QCocoaWindow *pw = self.helper.platformWindow;
    if (!pw || pw->m_isNSWindowChild)
        return NO;

    if (pw->shouldRefuseKeyWindowAndFirstResponder())
        return NO;

    // The default implementation returns NO for title-bar less windows,
    // override and return yes here to make sure popup windows such as
    // the combobox popup can become the key window.
    return YES;
}

- (BOOL)canBecomeMainWindow
{
    BOOL canBecomeMain = YES; // By default, windows can become the main window

    // Windows with a transient parent (such as combobox popup windows)
    // cannot become the main window:
    QCocoaWindow *pw = self.helper.platformWindow;
    if (!pw || pw->m_isNSWindowChild || pw->window()->transientParent())
        canBecomeMain = NO;

    return canBecomeMain;
}

- (void) sendEvent: (NSEvent*) theEvent
{
    [self.helper handleWindowEvent:theEvent];
}

- (void)superSendEvent:(NSEvent *)theEvent
{
    [super sendEvent:theEvent];
}

- (void)closeAndRelease
{
    [self close];

    if (self.helper.grabbingMouse) {
        self.helper.releaseOnMouseUp = YES;
    } else {
        [self.helper detachFromPlatformWindow];
        [self release];
    }
}

- (void)dealloc
{
    [_helper clearWindow];
    [_helper release];
    _helper = nil;
    [super dealloc];
}

@end

@implementation QNSPanel

@synthesize helper = _helper;

- (id)initWithContentRect:(NSRect)contentRect
      styleMask:(NSUInteger)windowStyle
      qPlatformWindow:(QCocoaWindow *)qpw
{
    self = [super initWithContentRect:contentRect
            styleMask:windowStyle
            backing:NSBackingStoreBuffered
            defer:NO]; // Deferring window creation breaks OpenGL (the GL context is
                       // set up before the window is shown and needs a proper window)

    if (self) {
        _helper = [[QNSWindowHelper alloc] initWithNSWindow:self platformWindow:qpw];
    }
    return self;
}

- (BOOL)canBecomeKeyWindow
{
    QCocoaWindow *pw = self.helper.platformWindow;
    if (!pw)
        return NO;

    if (pw->shouldRefuseKeyWindowAndFirstResponder())
        return NO;

    // Only tool or dialog windows should become key:
    Qt::WindowType type = pw->window()->type();
    if (type == Qt::Tool || type == Qt::Dialog)
        return YES;

    return NO;
}

- (void) sendEvent: (NSEvent*) theEvent
{
    [self.helper handleWindowEvent:theEvent];
}

- (void)superSendEvent:(NSEvent *)theEvent
{
    [super sendEvent:theEvent];
}

- (void)closeAndRelease
{
    [self.helper detachFromPlatformWindow];
    [self close];
    [self release];
}

- (void)dealloc
{
    [_helper clearWindow];
    [_helper release];
    _helper = nil;
    [super dealloc];
}

@end

const int QCocoaWindow::NoAlertRequest = -1;

QCocoaWindow::QCocoaWindow(QWindow *tlw)
    : QPlatformWindow(tlw)
    , m_contentView(nil)
    , m_qtView(nil)
    , m_nsWindow(0)
    , m_forwardWindow(0)
    , m_lazyNativeViewAndWindows(true)
    , m_lazyNativeViewCreated(false)
    , m_lazyNativeWindowCreated(false)
    , m_contentViewIsEmbedded(false)
    , m_contentViewIsToBeEmbedded(false)
    , m_ownsQtView(true)
    , m_parentCocoaWindow(0)
    , m_isNSWindowChild(false)
    , m_effectivelyMaximized(false)
    , m_synchedWindowState(Qt::WindowActive)
    , m_windowModality(Qt::NonModal)
    , m_windowUnderMouse(false)
    , m_inConstructor(true)
    , m_inSetVisible(false)
    , m_inSetGeometry(false)
    , m_inSetStyleMask(false)
#ifndef QT_NO_OPENGL
    , m_glContext(0)
#endif
    , m_menubar(0)
    , m_windowCursor(0)
    , m_hasModalSession(false)
    , m_frameStrutEventsEnabled(false)
    , m_geometryUpdateExposeAllowed(false)
    , m_registerTouchCount(0)
    , m_resizableTransientParent(false)
    , m_hiddenByClipping(false)
    , m_hiddenByAncestor(false)
    , m_inLayerMode(false)
    , m_useRasterLayerUpdate(false)
    , m_alertRequest(NoAlertRequest)
    , monitor(nil)
    , m_drawContentBorderGradient(false)
    , m_topContentBorderThickness(0)
    , m_bottomContentBorderThickness(0)
    , m_normalGeometry(QRect(0,0,-1,-1))
{
    qCDebug(lcQpaCocoaWindow) << "QCocoaWindow::QCocoaWindow" << window();

    QMacAutoReleasePool pool;

    // At this point QPlatformWindow::geometry() may contain the user-requested
    // geometry. Call the initalGeometry helper which will give it a default geometry
    // if there was no user geometry.
    QPlatformWindow::setGeometry(initialGeometry(window(),
                                 QPlatformWindow::geometry(), defaultWindowWidth, defaultWindowHeight));

    // Propagate updated geometry back to QWindow. This will cause a call to QCocoaWindow::setGeometry()
    // but we'll check m_inConstructor and return early.
    tlw->setGeometry(QPlatformWindow::geometry()); // ### QHighDPI

    if (tlw->type() == Qt::ForeignWindow) {
        NSView *foreignView = (NSView *)WId(tlw->property("_q_foreignWinId").value<WId>());
        setContentView(foreignView);
    } else {
        if (!m_lazyNativeViewAndWindows)
            createNativeView();
    }

    if (!m_lazyNativeViewAndWindows) {
        createNativeWindow();
        setCocoaGeometry(QPlatformWindow::geometry());
        if (tlw->isTopLevel())
            setWindowIcon(tlw->icon());
    }
    m_inConstructor = false;
}

QCocoaWindow::~QCocoaWindow()
{
    qCDebug(lcQpaCocoaWindow) << "QCocoaWindow::~QCocoaWindow" << window();

    // Stop and destroy display link
    [m_qtView destroyDisplayLink];

    QMacAutoReleasePool pool;
    [m_nsWindow makeFirstResponder:nil];
    [m_nsWindow setContentView:nil];
    [m_nsWindow.helper detachFromPlatformWindow];
    if (m_isNSWindowChild) {
        if (m_parentCocoaWindow)
            m_parentCocoaWindow->removeChildWindow(this);
    } else if ([contentView() superview]) {
        [contentView() removeFromSuperview];
    }

    removeMonitor();

    // Make sure to disconnect observer in all case if view is valid
    // to avoid notifications received when deleting when using Qt::AA_NativeWindows attribute
    if (m_qtView) {
        [[NSNotificationCenter defaultCenter] removeObserver:m_qtView];
    }

    // The QNSView object may outlive the corresponding QCocoaWindow object,
    // for example during app shutdown when the QNSView is embedded in a
    // foreign NSView hiearchy. Clear the pointers to the QWindow/QCocoaWindow
    // here to make sure QNSView does not dereference stale pointers.
    if (m_qtView) {
        [m_qtView clearQWindowPointers];
    }

    // While it is unlikely that this window will be in the popup stack
    // during deletetion we clear any pointers here to make sure.
    if (QCocoaIntegration::instance()) {
        QCocoaIntegration::instance()->popupWindowStack()->removeAll(this);
    }

    foreach (QCocoaWindow *child, m_childWindows) {
        [m_nsWindow removeChildWindow:child->nativeWindow()];
        child->m_parentCocoaWindow = 0;
    }

    [m_contentView release];
    [m_nsWindow release];
    [m_windowCursor release];
}

QCocoaWindow *QCocoaWindow::get(QWindow *window)
{
    if (!window)
        return  0;
    return static_cast<QCocoaWindow *>(window->handle());
}

QSurfaceFormat QCocoaWindow::format() const
{
    QSurfaceFormat format = window()->requestedFormat();

    // Upgrade the default surface format to include an alpha channel. The default RGB format
    // causes Cocoa to spend an unreasonable amount of time converting it to RGBA internally.
    if (format == QSurfaceFormat())
        format.setAlphaBufferSize(8);
    return format;
}

void QCocoaWindow::setGeometry(const QRect &rectIn)
{
    qCDebug(lcQpaCocoaWindow) << "QCocoaWindow::setGeometry" << window() << rectIn;

    // Refuse external geometry updates while in the QCocoaWindow constructor. This
    // can happen if/when QCocoaWindow wants to update the QWindow geometry.
    if (m_inConstructor)
        return;

    QRect rect = rectIn;

    QBoolBlocker inSetGeometry(m_inSetGeometry, true);

    qDebug() << "QCocoaWindow::setGeometry" << rectIn << geometry();

    // Determine if this is a call from QWindow::setFramePosition(). If so,
    // the position includes the frame. Size is still the content size.
    if (qt_window_private(const_cast<QWindow *>(window()))->positionPolicy
            == QWindowPrivate::WindowFrameInclusive) {
        const QMargins margins = frameMargins();

        rect.moveTopLeft(rect.topLeft() + QPoint(margins.left(), margins.top()));
    }

    if (m_lazyNativeViewAndWindows && !m_lazyNativeViewCreated) {
        QPlatformWindow::setGeometry(rect);
        return;
    }

    setCocoaGeometry(rect);
}

QRect QCocoaWindow::geometry() const
{
    // QWindows that are embedded in a NSView hiearchy may be considered
    // top-level from Qt's point of view but are not from Cocoa's point
    // of view. Embedded QWindows get global (screen) geometry.
    if (m_contentViewIsEmbedded) {
        NSPoint windowPoint = [contentView() convertPoint:NSMakePoint(0, 0) toView:nil];
        NSRect screenRect = [[contentView() window] convertRectToScreen:NSMakeRect(windowPoint.x, windowPoint.y, 1, 1)];
        NSPoint screenPoint = screenRect.origin;
        QPoint position = qt_mac_flipPoint(screenPoint).toPoint();
        QSize size = qt_mac_toQRect([contentView() bounds]).size();
        return QRect(position, size);
    }

    return QPlatformWindow::geometry();
}

void QCocoaWindow::setCocoaGeometry(const QRect &rect)
{
    qCDebug(lcQpaCocoaWindow) << "QCocoaWindow::setCocoaGeometry" << window() << rect;
    QMacAutoReleasePool pool;

    // Special case for child NSWindows where child NSWindow geometry needs to
    // be clipped against parent NSWindow geometry.
    if (m_isNSWindowChild) {
        QPlatformWindow::setGeometry(rect);
        NSWindow *parentNSWindow = m_parentCocoaWindow->nativeWindow();
        NSRect parentWindowFrame = [parentNSWindow contentRectForFrameRect:parentNSWindow.frame];
        clipWindow(parentWindowFrame);

        // Call this here: updateGeometry in qnsview.mm is a no-op for this case
        QWindowSystemInterface::handleGeometryChange(window(), rect);
        return;
    }

    // Set the native NSView or NSWindow geometry. If there is a NSWindow then
    // setting its geometry will also update its content view geometry.
    if (m_nsWindow) {

        // Triggering an immediate display here seems to be the only way to
        // have flicker-free window size animations. However, this will also
        // send drawRect calls for hidden windows, which we don't want since
        // they might cause QNSView to send expose events and/or make the window
        // visible. Only ask to display if the native window is visible.
        bool display = (m_nsWindow.occlusionState & NSWindowOcclusionStateVisible);

        [m_nsWindow setFrame:[m_nsWindow frameRectForContentRect:qt_mac_flipRect(rect)]
                                                         display:display
                                                         animate:NO];
    } else {
        [contentView() setFrame:qt_mac_toNSRect(rect)];
    }

    // Set QPlatformWindow geometry if the controlled NSView is a 'foreign' view
    // and not a QNSView. (For the QNSView case this is done in [QNSView updateGeometry].)
    if (!qtView())
        QPlatformWindow::setGeometry(rect);
}

void QCocoaWindow::clipChildWindows()
{
    foreach (QCocoaWindow *childWindow, m_childWindows) {
        childWindow->clipWindow(nativeWindow().frame);
    }
}

void QCocoaWindow::clipWindow(const NSRect &clipRect)
{
    if (!m_isNSWindowChild)
        return;

    NSRect clippedWindowRect = NSZeroRect;
    if (!NSIsEmptyRect(clipRect)) {
        NSRect windowFrame = qt_mac_flipRect(QRect(window()->mapToGlobal(QPoint(0, 0)), geometry().size()));
        clippedWindowRect = NSIntersectionRect(windowFrame, clipRect);
        // Clipping top/left offsets the content. Move it back.
        NSPoint contentViewOffset = NSMakePoint(qMax(CGFloat(0), NSMinX(clippedWindowRect) - NSMinX(windowFrame)),
                                                qMax(CGFloat(0), NSMaxY(windowFrame) - NSMaxY(clippedWindowRect)));
        [contentView() setBoundsOrigin:contentViewOffset];
    }

    if (NSIsEmptyRect(clippedWindowRect)) {
        if (!m_hiddenByClipping) {
            // We dont call hide() here as we will recurse further down
            [nativeWindow() orderOut:nil];
            m_hiddenByClipping = true;
        }
    } else {
        [nativeWindow() setFrame:clippedWindowRect display:YES animate:NO];
        if (m_hiddenByClipping) {
            m_hiddenByClipping = false;
            if (!m_hiddenByAncestor) {
                [nativeWindow() orderFront:nil];
                m_parentCocoaWindow->reinsertChildWindow(this);
            }
        }
    }

    // recurse
    foreach (QCocoaWindow *childWindow, m_childWindows) {
        childWindow->clipWindow(clippedWindowRect);
    }
}

void QCocoaWindow::hide(bool becauseOfAncestor)
{
    bool visible = [nativeWindow() isVisible];

    if (!m_hiddenByAncestor && !visible) // Already explicitly hidden
        return;
    if (m_hiddenByAncestor && becauseOfAncestor) // Trying to hide some child again
        return;

    m_hiddenByAncestor = becauseOfAncestor;

    if (!visible) // Could have been clipped before
        return;

    foreach (QCocoaWindow *childWindow, m_childWindows)
        childWindow->hide(true);

    [nativeWindow() orderOut:nil];
}

void QCocoaWindow::show(bool becauseOfAncestor)
{
    if ([nativeWindow() isVisible])
        return;

    if (m_parentCocoaWindow && ![m_parentCocoaWindow->nativeWindow() isVisible]) {
        m_hiddenByAncestor = true; // Parent still hidden, don't show now
    } else if ((becauseOfAncestor == m_hiddenByAncestor) // Was NEITHER explicitly hidden
               && !m_hiddenByClipping) { // ... NOR clipped
        if (m_isNSWindowChild) {
            m_hiddenByAncestor = false;
            setCocoaGeometry(windowGeometry());
        }
        if (!m_hiddenByClipping) { // setCocoaGeometry() can change the clipping status
            [nativeWindow() orderFront:nil];
            if (m_isNSWindowChild)
                m_parentCocoaWindow->reinsertChildWindow(this);
            foreach (QCocoaWindow *childWindow, m_childWindows)
                childWindow->show(true);
        }
    }
}

void QCocoaWindow::setVisible(bool visible)
{
    qCDebug(lcQpaCocoaWindow) << "QCocoaWindow::setVisible" << window() << visible;

    if (m_isNSWindowChild && m_hiddenByClipping)
        return;

    m_inSetVisible = true;

    QMacAutoReleasePool pool;
    QCocoaWindow *parentCocoaWindow = 0;
    if (window()->transientParent())
        parentCocoaWindow = static_cast<QCocoaWindow *>(window()->transientParent()->handle());

    if (visible) {

        // Native views and windows are needed to make the window visible. Create
        // them if this has not already been done.
        if (m_lazyNativeViewAndWindows && !m_lazyNativeViewCreated) {
            createNativeView();
            createNativeWindow();
        }

        // We need to recreate if the modality has changed as the style mask will need updating
        if (m_windowModality != window()->modality())
            recreateWindow(parent());

        // Register popup windows. The Cocoa platform plugin will forward mouse events
        // to them and close them when needed.
        if (window()->type() == Qt::Popup || window()->type() == Qt::ToolTip)
            QCocoaIntegration::instance()->pushPopupWindow(this);

        if (parentCocoaWindow) {
            // The parent window might have moved while this window was hidden,
            // update the window geometry if there is a parent.
            setGeometry(windowGeometry());

            if (window()->type() == Qt::Popup) {
                // QTBUG-30266: a window should not be resizable while a transient popup is open
                // Since this isn't a native popup, the window manager doesn't close the popup when you click outside
                NSUInteger parentStyleMask = [parentCocoaWindow->nativeWindow() styleMask];
                if ((m_resizableTransientParent = (parentStyleMask & NSResizableWindowMask))
                    && !([parentCocoaWindow->nativeWindow() styleMask] & NSFullScreenWindowMask))
                    [parentCocoaWindow->nativeWindow() setStyleMask:parentStyleMask & ~NSResizableWindowMask];
            }

        }

        if (m_nsWindow) {
            // setWindowState might have been called while the window was hidden and
            // will not change the NSWindow state in that case. Sync up here:
            syncWindowState(window()->windowState());

            if (window()->windowState() != Qt::WindowMinimized) {
                if ((window()->modality() == Qt::WindowModal
                     || window()->type() == Qt::Sheet)
                        && parentCocoaWindow) {
                    // show the window as a sheet
                    [NSApp beginSheet:nativeWindow() modalForWindow:parentCocoaWindow->nativeWindow() modalDelegate:nil didEndSelector:nil contextInfo:nil];
                } else if (window()->modality() != Qt::NonModal) {
                    // show the window as application modal
                    QCocoaEventDispatcher *cocoaEventDispatcher = qobject_cast<QCocoaEventDispatcher *>(QGuiApplication::instance()->eventDispatcher());
                    Q_ASSERT(cocoaEventDispatcher != 0);
                    QCocoaEventDispatcherPrivate *cocoaEventDispatcherPrivate = static_cast<QCocoaEventDispatcherPrivate *>(QObjectPrivate::get(cocoaEventDispatcher));
                    cocoaEventDispatcherPrivate->beginModalSession(window());
                    m_hasModalSession = true;
                } else if ([nativeWindow() canBecomeKeyWindow]) {
                    QCocoaEventDispatcher *cocoaEventDispatcher = qobject_cast<QCocoaEventDispatcher *>(QGuiApplication::instance()->eventDispatcher());
                    QCocoaEventDispatcherPrivate *cocoaEventDispatcherPrivate = 0;
                    if (cocoaEventDispatcher)
                        cocoaEventDispatcherPrivate = static_cast<QCocoaEventDispatcherPrivate *>(QObjectPrivate::get(cocoaEventDispatcher));

                    if (!(cocoaEventDispatcherPrivate && cocoaEventDispatcherPrivate->currentModalSession()))
                        [nativeWindow() makeKeyAndOrderFront:nil];
                    else
                        [nativeWindow() orderFront:nil];

                    foreach (QCocoaWindow *childWindow, m_childWindows)
                        childWindow->show(true);
                } else {
                    show();
                }

                // We want the events to properly reach the popup, dialog, and tool
                if ((window()->type() == Qt::Popup || window()->type() == Qt::Dialog || window()->type() == Qt::Tool)
                    && [nativeWindow() isKindOfClass:[NSPanel class]]) {
                    [(NSPanel *)nativeWindow() setWorksWhenModal:YES];
                    if (!(parentCocoaWindow && window()->transientParent()->isActive()) && window()->type() == Qt::Popup) {
                        removeMonitor();
                        monitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSLeftMouseDownMask|NSRightMouseDownMask|NSOtherMouseDownMask|NSMouseMovedMask handler:^(NSEvent *e) {
                            QPointF localPoint = qt_mac_flipPoint([NSEvent mouseLocation]);
                            QWindowSystemInterface::handleMouseEvent(window(), window()->mapFromGlobal(localPoint.toPoint()), localPoint,
                                                                     cocoaButton2QtButton([e buttonNumber]));
                        }];
                    }
                }
            }
        }
        // In some cases, e.g. QDockWidget, the content view is hidden before moving to its own
        // Cocoa window, and then shown again. Therefore, we test for the view being hidden even
        // if it's attached to an NSWindow.
        if ([contentView() isHidden])
            [contentView() setHidden:NO];
    } else {
        // qDebug() << "close" << this;
#ifndef QT_NO_OPENGL
        if (m_glContext)
            m_glContext->windowWasHidden();
#endif
        QCocoaEventDispatcher *cocoaEventDispatcher = qobject_cast<QCocoaEventDispatcher *>(QGuiApplication::instance()->eventDispatcher());
        QCocoaEventDispatcherPrivate *cocoaEventDispatcherPrivate = 0;
        if (cocoaEventDispatcher)
            cocoaEventDispatcherPrivate = static_cast<QCocoaEventDispatcherPrivate *>(QObjectPrivate::get(cocoaEventDispatcher));
        if (nativeWindow()) {
            if (m_hasModalSession) {
                if (cocoaEventDispatcherPrivate)
                    cocoaEventDispatcherPrivate->endModalSession(window());
                m_hasModalSession = false;
            } else {
                if ([nativeWindow() isSheet])
                    [NSApp endSheet:nativeWindow()];
            }

            hide();
            if (nativeWindow() == [NSApp keyWindow]
                && !(cocoaEventDispatcherPrivate && cocoaEventDispatcherPrivate->currentModalSession())) {
                // Probably because we call runModalSession: outside [NSApp run] in QCocoaEventDispatcher
                // (e.g., when show()-ing a modal QDialog instead of exec()-ing it), it can happen that
                // the current NSWindow is still key after being ordered out. Then, after checking we
                // don't have any other modal session left, it's safe to make the main window key again.
                NSWindow *mainWindow = [NSApp mainWindow];
                if (mainWindow && [mainWindow canBecomeKeyWindow])
                    [mainWindow makeKeyWindow];
            }
        } else {
            [contentView() setHidden:YES];
        }
        removeMonitor();

        if (window()->type() == Qt::Popup || window()->type() == Qt::ToolTip)
            QCocoaIntegration::instance()->popupWindowStack()->removeAll(this);

        if (parentCocoaWindow && window()->type() == Qt::Popup) {
            if (m_resizableTransientParent
                && !([parentCocoaWindow->nativeWindow() styleMask] & NSFullScreenWindowMask))
                // QTBUG-30266: a window should not be resizable while a transient popup is open
                [parentCocoaWindow->nativeWindow() setStyleMask:[parentCocoaWindow->nativeWindow() styleMask] | NSResizableWindowMask];
        }
    }

    m_inSetVisible = false;
}

NSInteger QCocoaWindow::windowLevel(Qt::WindowFlags flags)
{
    Qt::WindowType type = static_cast<Qt::WindowType>(int(flags & Qt::WindowType_Mask));

    NSInteger windowLevel = NSNormalWindowLevel;

    if (type == Qt::Tool)
        windowLevel = NSFloatingWindowLevel;
    else if ((type & Qt::Popup) == Qt::Popup)
        windowLevel = NSPopUpMenuWindowLevel;

    // StayOnTop window should appear above Tool windows.
    if (flags & Qt::WindowStaysOnTopHint)
        windowLevel = NSModalPanelWindowLevel;
    // Tooltips should appear above StayOnTop windows.
    if (type == Qt::ToolTip)
        windowLevel = NSScreenSaverWindowLevel;

    // Any "special" window should be in at least the same level as its parent.
    if (type != Qt::Window) {
        const QWindow * const transientParent = window()->transientParent();
        const QCocoaWindow * const transientParentWindow = transientParent ? static_cast<QCocoaWindow *>(transientParent->handle()) : 0;
        if (transientParentWindow)
            windowLevel = qMax([transientParentWindow->nativeWindow() level], windowLevel);
    }

    return windowLevel;
}

NSUInteger QCocoaWindow::windowStyleMask(Qt::WindowFlags flags)
{
    Qt::WindowType type = static_cast<Qt::WindowType>(int(flags & Qt::WindowType_Mask));
    NSInteger styleMask = NSBorderlessWindowMask;
    if (flags & Qt::FramelessWindowHint)
        return styleMask;
    if ((type & Qt::Popup) == Qt::Popup) {
        if (!windowIsPopupType(type)) {
            styleMask = NSUtilityWindowMask | NSResizableWindowMask;
            if (!(flags & Qt::CustomizeWindowHint)) {
                styleMask |= NSClosableWindowMask | NSMiniaturizableWindowMask | NSTitledWindowMask;
            } else {
                if (flags & Qt::WindowTitleHint)
                    styleMask |= NSTitledWindowMask;
                if (flags & Qt::WindowCloseButtonHint)
                    styleMask |= NSClosableWindowMask;
                if (flags & Qt::WindowMinimizeButtonHint)
                    styleMask |= NSMiniaturizableWindowMask;
            }
        }
    } else {
        if (type == Qt::Window && !(flags & Qt::CustomizeWindowHint)) {
            styleMask = (NSResizableWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask | NSTitledWindowMask);
        } else if (type == Qt::Dialog) {
            if (flags & Qt::CustomizeWindowHint) {
                if (flags & Qt::WindowMaximizeButtonHint)
                    styleMask = NSResizableWindowMask;
                if (flags & Qt::WindowTitleHint)
                    styleMask |= NSTitledWindowMask;
                if (flags & Qt::WindowCloseButtonHint)
                    styleMask |= NSClosableWindowMask;
                if (flags & Qt::WindowMinimizeButtonHint)
                    styleMask |= NSMiniaturizableWindowMask;
            } else {
                styleMask = NSResizableWindowMask | NSClosableWindowMask | NSTitledWindowMask;
            }
        } else {
            if (flags & Qt::WindowMaximizeButtonHint)
                styleMask |= NSResizableWindowMask;
            if (flags & Qt::WindowTitleHint)
                styleMask |= NSTitledWindowMask;
            if (flags & Qt::WindowCloseButtonHint)
                styleMask |= NSClosableWindowMask;
            if (flags & Qt::WindowMinimizeButtonHint)
                styleMask |= NSMiniaturizableWindowMask;
        }
    }

    if (m_drawContentBorderGradient)
        styleMask |= NSTexturedBackgroundWindowMask;

    return styleMask;
}

void QCocoaWindow::setWindowShadow(Qt::WindowFlags flags)
{
    bool keepShadow = !(flags & Qt::NoDropShadowWindowHint);
    [nativeWindow() setHasShadow:(keepShadow ? YES : NO)];
}

void QCocoaWindow::setWindowZoomButton(Qt::WindowFlags flags)
{
    // Disable the zoom (maximize) button for fixed-sized windows and customized
    // no-WindowMaximizeButtonHint windows. From a Qt perspective it migth be expected
    // that the button would be removed in the latter case, but disabling it is more
    // in line with the platform style guidelines.
    bool fixedSizeNoZoom = (windowMinimumSize().isValid() && windowMaximumSize().isValid()
                            && windowMinimumSize() == windowMaximumSize());
    bool customizeNoZoom = ((flags & Qt::CustomizeWindowHint) && !(flags & Qt::WindowMaximizeButtonHint));
    [[nativeWindow() standardWindowButton:NSWindowZoomButton] setEnabled:!(fixedSizeNoZoom || customizeNoZoom)];
}

void QCocoaWindow::setWindowFlags(Qt::WindowFlags flags)
{
    if (nativeWindow() && !m_isNSWindowChild) {
        NSUInteger styleMask = windowStyleMask(flags);
        NSInteger level = this->windowLevel(flags);
        // While setting style mask we can have -updateGeometry calls on a content
        // view with null geometry, reporting an invalid coordinates as a result.
        m_inSetStyleMask = true;
        [nativeWindow() setStyleMask:styleMask];
        m_inSetStyleMask = false;
        [nativeWindow() setLevel:level];
        setWindowShadow(flags);
        if (!(flags & Qt::FramelessWindowHint)) {
            setWindowTitle(window()->title());
        }

        Qt::WindowType type = window()->type();
        if ((type & Qt::Popup) != Qt::Popup && (type & Qt::Dialog) != Qt::Dialog) {
            NSWindowCollectionBehavior behavior = [nativeWindow() collectionBehavior];
            if (flags & Qt::WindowFullscreenButtonHint) {
                behavior |= NSWindowCollectionBehaviorFullScreenPrimary;
                behavior &= ~NSWindowCollectionBehaviorFullScreenAuxiliary;
            } else {
                behavior |= NSWindowCollectionBehaviorFullScreenAuxiliary;
                behavior &= ~NSWindowCollectionBehaviorFullScreenPrimary;
            }
            [nativeWindow() setCollectionBehavior:behavior];
        }
        setWindowZoomButton(flags);
    }

    m_windowFlags = flags;
}

void QCocoaWindow::setWindowState(Qt::WindowState state)
{
    if (window()->isVisible())
        syncWindowState(state);  // Window state set for hidden windows take effect when show() is called.
}

void QCocoaWindow::setWindowTitle(const QString &title)
{
    QMacAutoReleasePool pool;
    if (!nativeWindow())
        return;

    CFStringRef windowTitle = QCFString::toCFStringRef(title);
    [nativeWindow() setTitle: const_cast<NSString *>(reinterpret_cast<const NSString *>(windowTitle))];
    CFRelease(windowTitle);
}

void QCocoaWindow::setWindowFilePath(const QString &filePath)
{
    QMacAutoReleasePool pool;
    if (!nativeWindow())
        return;

    QFileInfo fi(filePath);
    [nativeWindow() setRepresentedFilename: fi.exists() ? QCFString::toNSString(filePath) : @""];
}

void QCocoaWindow::setWindowIcon(const QIcon &icon)
{
    QMacAutoReleasePool pool;

    NSButton *iconButton = [nativeWindow() standardWindowButton:NSWindowDocumentIconButton];
    if (iconButton == nil) {
        if (icon.isNull())
            return;
        NSString *title = QCFString::toNSString(window()->title());
        [nativeWindow() setRepresentedURL:[NSURL fileURLWithPath:title]];
        iconButton = [nativeWindow() standardWindowButton:NSWindowDocumentIconButton];
    }
    if (icon.isNull()) {
        [iconButton setImage:nil];
    } else {
        QPixmap pixmap = icon.pixmap(QSize(22, 22));
        NSImage *image = static_cast<NSImage *>(qt_mac_create_nsimage(pixmap));
        [iconButton setImage:image];
        [image release];
    }
}

void QCocoaWindow::setAlertState(bool enabled)
{
    if (m_alertRequest == NoAlertRequest && enabled) {
        m_alertRequest = [NSApp requestUserAttention:NSCriticalRequest];
    } else if (m_alertRequest != NoAlertRequest && !enabled) {
        [NSApp cancelUserAttentionRequest:m_alertRequest];
        m_alertRequest = NoAlertRequest;
    }
}

bool QCocoaWindow::isAlertState() const
{
    return m_alertRequest != NoAlertRequest;
}

void QCocoaWindow::raise()
{
    qCDebug(lcQpaCocoaWindow) << "QCocoaWindow::raise" << window();

    // ### handle spaces (see Qt 4 raise_sys in qwidget_mac.mm)
    if (!nativeWindow())
        return;
    if (m_isNSWindowChild) {
        QList<QCocoaWindow *> &siblings = m_parentCocoaWindow->m_childWindows;
        siblings.removeOne(this);
        siblings.append(this);
        if (m_hiddenByClipping)
            return;
    }
    if ([nativeWindow() isVisible]) {
        if (m_isNSWindowChild) {
            // -[NSWindow orderFront:] doesn't work with attached windows.
            // The only solution is to remove and add the child window.
            // This will place it on top of all the other NSWindows.
            NSWindow *parentNSWindow = m_parentCocoaWindow->nativeWindow();
            [parentNSWindow removeChildWindow:nativeWindow()];
            [parentNSWindow addChildWindow:nativeWindow() ordered:NSWindowAbove];
        } else {
            {
                // Clean up autoreleased temp objects from orderFront immediately.
                // Failure to do so has been observed to cause leaks also beyond any outer
                // autorelease pool (for example around a complete QWindow
                // construct-show-raise-hide-delete cyle), counter to expected autoreleasepool
                // behavior.
                QMacAutoReleasePool pool;
                [nativeWindow() orderFront: nativeWindow()];
            }
            static bool raiseProcess = qt_mac_resolveOption(true, "QT_MAC_SET_RAISE_PROCESS");
            if (raiseProcess) {
                ProcessSerialNumber psn;
                GetCurrentProcess(&psn);
                SetFrontProcessWithOptions(&psn, kSetFrontProcessFrontWindowOnly);
            }
        }
    }
}

void QCocoaWindow::lower()
{
    qCDebug(lcQpaCocoaWindow) << "QCocoaWindow::lower" << window();
    if (!nativeWindow())
        return;
    if (m_isNSWindowChild) {
        QList<QCocoaWindow *> &siblings = m_parentCocoaWindow->m_childWindows;
        siblings.removeOne(this);
        siblings.prepend(this);
        if (m_hiddenByClipping)
            return;
    }
    if ([nativeWindow() isVisible]) {
        if (m_isNSWindowChild) {
            // -[NSWindow orderBack:] doesn't work with attached windows.
            // The only solution is to remove and add all the child windows except this one.
            // This will keep the current window at the bottom while adding the others on top of it,
            // hopefully in the same order (this is not documented anywhere in the Cocoa documentation).
            NSWindow *parentNSWindow = m_parentCocoaWindow->nativeWindow();
            NSArray *children = [parentNSWindow.childWindows copy];
            for (NSWindow *child in children)
                if (nativeWindow() != child) {
                    [parentNSWindow removeChildWindow:child];
                    [parentNSWindow addChildWindow:child ordered:NSWindowAbove];
                }
        } else {
            [nativeWindow() orderBack: nativeWindow()];
        }
    }
}

bool QCocoaWindow::isExposed() const
{
    return !m_exposedSize.isEmpty();
}

bool QCocoaWindow::isOpaque() const
{
    // OpenGL surfaces can be ordered either above(default) or below the NSWindow.
    // When ordering below the window must be tranclucent.
    static GLint openglSourfaceOrder = qt_mac_resolveOption(1, "QT_MAC_OPENGL_SURFACE_ORDER");

    bool translucent = (window()->format().alphaBufferSize() > 0
                        || window()->opacity() < 1
                        || (qtView() && [qtView() hasMask]))
                        || (surface()->supportsOpenGL() && openglSourfaceOrder == -1);
    return !translucent;
}

void QCocoaWindow::propagateSizeHints()
{
    QMacAutoReleasePool pool;

    // Don't propagate if the there is no native NSWindow or it has not been
    // created yet. In the latter case this function will be called again
    // at native window creation time.
    if (!m_nsWindow)
        return;

    qCDebug(lcQpaCocoaWindow) << "QCocoaWindow::propagateSizeHints" << window() << "\n"
                              << "       min/max" << windowMinimumSize() << windowMaximumSize() << "\n"
                              << "size increment" << windowSizeIncrement() << "\n"
                              << "      basesize" << windowBaseSize() << "\n"
                              << "      geometry" << windowGeometry();

    // Set the minimum content size.
    const QSize minimumSize = windowMinimumSize();
    if (!minimumSize.isValid()) // minimumSize is (-1, -1) when not set. Make that (0, 0) for Cocoa.
        [m_nsWindow setContentMinSize : NSMakeSize(0.0, 0.0)];
    [m_nsWindow setContentMinSize : NSMakeSize(minimumSize.width(), minimumSize.height())];

    // Set the maximum content size.
    const QSize maximumSize = windowMaximumSize();
    [m_nsWindow setContentMaxSize : NSMakeSize(maximumSize.width(), maximumSize.height())];

    // The window may end up with a fixed size; in this case the zoom button should be disabled.
    setWindowZoomButton(m_windowFlags);

    // sizeIncrement is observed to take values of (-1, -1) and (0, 0) for windows that should be
    // resizable and that have no specific size increment set. Cocoa expects (1.0, 1.0) in this case.
    const QSize sizeIncrement = windowSizeIncrement();
    if (!sizeIncrement.isEmpty())
        [m_nsWindow setResizeIncrements : qt_mac_toNSSize(sizeIncrement)];
    else
        [m_nsWindow setResizeIncrements : NSMakeSize(1.0, 1.0)];

    QRect rect = geometry();
    QSize baseSize = windowBaseSize();
    if (!baseSize.isNull() && baseSize.isValid()) {
        [m_nsWindow setFrame:NSMakeRect(rect.x(), rect.y(), baseSize.width(), baseSize.height()) display:NO];
    }
}

void QCocoaWindow::setOpacity(qreal level)
{
    qCDebug(lcQpaCocoaWindow) << "QCocoaWindow::setOpacity" << level;
    if (nativeWindow()) {
        [nativeWindow() setAlphaValue:level];
        [nativeWindow() setOpaque: isOpaque()];
    }
}

void QCocoaWindow::setMask(const QRegion &region)
{
    qCDebug(lcQpaCocoaWindow) << "QCocoaWindow::setMask" << window() << region;
    if (nativeWindow())
        [nativeWindow() setBackgroundColor:[NSColor clearColor]];

    [qtView() setMaskRegion:&region];
    [nativeWindow() setOpaque: isOpaque()];
}

bool QCocoaWindow::setKeyboardGrabEnabled(bool grab)
{
    qCDebug(lcQpaCocoaWindow) << "QCocoaWindow::setKeyboardGrabEnabled" << window() << grab;
    if (!nativeWindow())
        return false;

    if (grab && ![nativeWindow() isKeyWindow])
        [nativeWindow() makeKeyWindow];
    else if (!grab && [nativeWindow() isKeyWindow])
        [nativeWindow() resignKeyWindow];
    return true;
}

bool QCocoaWindow::setMouseGrabEnabled(bool grab)
{
    qCDebug(lcQpaCocoaWindow) << "QCocoaWindow::setMouseGrabEnabled" << window() << grab;
    if (!nativeWindow())
        return false;

    if (grab && ![nativeWindow() isKeyWindow])
        [nativeWindow() makeKeyWindow];
    else if (!grab && [nativeWindow() isKeyWindow])
        [nativeWindow() resignKeyWindow];
    return true;
}

WId QCocoaWindow::winId() const
{
    return WId(contentView());
}

void QCocoaWindow::setParent(const QPlatformWindow *parentWindow)
{
    qCDebug(lcQpaCocoaWindow) << "QCocoaWindow::setParent" << window() << (parentWindow ? parentWindow->window() : 0);

    // recreate the window for compatibility
    bool unhideAfterRecreate = parentWindow && !m_contentViewIsToBeEmbedded && ![contentView() isHidden];
    recreateWindow(parentWindow);
    if (unhideAfterRecreate)
        [contentView() setHidden:NO];
    setCocoaGeometry(geometry());
}

// Creates a QNSView for this window.
void QCocoaWindow::createNativeView()
{
    m_lazyNativeViewCreated = true;
    m_qtView = [[QNSView alloc] initWithQWindow:window() platformWindow:this];
    m_contentView = m_qtView;

    // Enable high-dpi OpenGL for retina displays. Enabling has the side
    // effect that Cocoa will start calling glViewport(0, 0, width, height),
    // overriding any glViewport calls in application code. This is usually not a
    // problem, except if the appilcation wants to have a "custom" viewport.
    // (like the hellogl example)
    if (window()->supportsOpenGL()) {
        BOOL enable = qt_mac_resolveOption(YES, window(), "_q_mac_wantsBestResolutionOpenGLSurface",
                                                          "QT_MAC_WANTS_BEST_RESOLUTION_OPENGL_SURFACE");
        [m_contentView setWantsBestResolutionOpenGLSurface:enable];
    }
    BOOL enable = qt_mac_resolveOption(NO, window(), "_q_mac_wantsLayer",
                                                     "QT_MAC_WANTS_LAYER");
    [m_contentView setWantsLayer:enable];
}

// Creates a NSWindow/NSPanel for this window.
void QCocoaWindow::createNativeWindow()
{
    m_lazyNativeWindowCreated = true;
    recreateWindow(parent());
}

// Returns the native NSView instance for this window. In lazy mode creates
// a QNSView if neccesary.
NSView *QCocoaWindow::contentView() const
{
    if (!m_lazyNativeViewAndWindows || m_lazyNativeViewCreated)
        return m_contentView;

    if (!m_contentView)
         const_cast<QCocoaWindow *>(this)->createNativeView();

    return m_contentView;
}

// Sets the native NSView instance for this window. This function
// is used when making QWindow control a foreign NSView.
void QCocoaWindow::setContentView(NSView *contentView)
{
    // This counts as running the view creation logic.
    m_lazyNativeViewCreated = true;

    // Remove and release the previous content view
    [m_contentView removeFromSuperview];
    [m_contentView release];

    // Insert and retain the new content view
    [contentView retain];
    m_contentView = contentView;
    m_qtView = 0; // The new content view is not a QNSView.
    recreateWindow(parent()); // Adds the content view to parent NSView
}

// Returns the native QNSView for this window. In lazy mode creates
// a QNSView if neccesary.
QNSView *QCocoaWindow::qtView() const
{
    if (!m_lazyNativeViewAndWindows || m_lazyNativeViewCreated)
        return m_qtView;

    // Don't create a QNSView if this QWindow is managing a foreign NSView.
    if (m_contentView)
        return nil;

    if (!m_qtView)
         const_cast<QCocoaWindow *>(this)->createNativeView();

    return m_qtView;
}

// Returns the native NSWindow for this window. In lazy mode creates
// it if neccesary.
NSWindow *QCocoaWindow::nativeWindow() const
{
    if (!m_lazyNativeViewAndWindows || m_lazyNativeWindowCreated)
        return m_nsWindow;

    const_cast<QCocoaWindow *>(this)->createNativeWindow();
    return m_nsWindow;
}

void QCocoaWindow::setEmbeddedInForeignView(bool embedded)
{
    m_contentViewIsToBeEmbedded = embedded;
    // Release any previosly created NSWindow.
    [m_nsWindow closeAndRelease];
    m_nsWindow = 0;
}

void QCocoaWindow::windowWillMove()
{
    // Close any open popups on window move
    while (QCocoaWindow *popup = QCocoaIntegration::instance()->popPopupWindow()) {
        QWindowSystemInterface::handleCloseEvent(popup->window());
        QWindowSystemInterface::flushWindowSystemEvents();
    }
}

void QCocoaWindow::windowDidMove()
{
    if (m_isNSWindowChild)
        return;

    [qtView() updateGeometry];
}

void QCocoaWindow::windowDidResize()
{
    if (!nativeWindow())
        return;

    if (m_isNSWindowChild)
        return;

    clipChildWindows();
    [qtView() updateGeometry];
}

void QCocoaWindow::windowDidEndLiveResize()
{
    if (m_synchedWindowState == Qt::WindowMaximized && ![nativeWindow() isZoomed]) {
        m_effectivelyMaximized = false;
        [qtView() notifyWindowStateChanged:Qt::WindowNoState];
    }
}

bool QCocoaWindow::windowShouldClose()
{
    qCDebug(lcQpaCocoaWindow) << "QCocoaWindow::windowShouldClose" << window();
   // This callback should technically only determine if the window
   // should (be allowed to) close, but since our QPA API to determine
   // that also involves actually closing the window we do both at the
   // same time, instead of doing the latter in windowWillClose.
    bool accepted = false;
    QWindowSystemInterface::handleCloseEvent(window(), &accepted);
    QWindowSystemInterface::flushWindowSystemEvents();
    return accepted;
}

void QCocoaWindow::setSynchedWindowStateFromWindow()
{
    if (QWindow *w = window())
        m_synchedWindowState = w->windowState();
}

bool QCocoaWindow::windowIsPopupType(Qt::WindowType type) const
{
    if (type == Qt::Widget)
        type = window()->type();
    if (type == Qt::Tool)
        return false; // Qt::Tool has the Popup bit set but isn't, at least on Mac.

    return ((type & Qt::Popup) == Qt::Popup);
}

#ifndef QT_NO_OPENGL
void QCocoaWindow::setCurrentContext(QCocoaGLContext *context)
{
    m_glContext = context;
}

QCocoaGLContext *QCocoaWindow::currentContext() const
{
    return m_glContext;
}
#endif

void QCocoaWindow::recreateWindow(const QPlatformWindow *parentWindow)
{
    qCDebug(lcQpaCocoaWindow) << "QCocoaWindow::recreateWindow" << window()
                              << "parent" << (parentWindow ? parentWindow->window() : 0);

    bool wasNSWindowChild = m_isNSWindowChild;
    BOOL requestNSWindowChild = qt_mac_resolveOption(NO, window(), "_q_platform_MacUseNSWindow",
                                                                   "QT_MAC_USE_NSWINDOW");
    m_isNSWindowChild = parentWindow && requestNSWindowChild;
    bool needsNSWindow = m_isNSWindowChild || (!parentWindow && !m_contentViewIsToBeEmbedded);

    QCocoaWindow *oldParentCocoaWindow = m_parentCocoaWindow;
    m_parentCocoaWindow = const_cast<QCocoaWindow *>(static_cast<const QCocoaWindow *>(parentWindow));
    if (m_parentCocoaWindow && m_isNSWindowChild) {
        QWindow *parentQWindow = m_parentCocoaWindow->window();
        if (!parentQWindow->property("_q_platform_MacUseNSWindow").toBool()) {
            parentQWindow->setProperty("_q_platform_MacUseNSWindow", QVariant(true));
            m_parentCocoaWindow->recreateWindow(m_parentCocoaWindow->m_parentCocoaWindow);
        }
    }

    bool usesNSPanel = [m_nsWindow isKindOfClass:[QNSPanel class]];

    // No child QNSWindow should notify its QNSView
    if (m_nsWindow && qtView() && m_parentCocoaWindow && !oldParentCocoaWindow)
        [[NSNotificationCenter defaultCenter] removeObserver:qtView()
                                              name:nil object:m_nsWindow];

    // Remove current window (if any)
    if ((m_nsWindow && !needsNSWindow) || (usesNSPanel != shouldUseNSPanel())) {
        [m_nsWindow closeAndRelease];
        if (wasNSWindowChild && oldParentCocoaWindow)
            oldParentCocoaWindow->removeChildWindow(this);
        m_nsWindow = 0;
    }

    if (needsNSWindow) {
        bool noPreviousWindow = m_nsWindow == 0;
        if (noPreviousWindow)
            m_nsWindow = createNSWindow();

        // Only non-child QNSWindows should notify their QNSViews
        // (but don't register more than once).
        if (qtView() && (noPreviousWindow || (wasNSWindowChild && !m_isNSWindowChild)))
            [[NSNotificationCenter defaultCenter] addObserver:qtView()
                                                  selector:@selector(windowNotification:)
                                                  name:nil // Get all notifications
                                                  object:m_nsWindow];

        if (oldParentCocoaWindow) {
            if (!m_isNSWindowChild || oldParentCocoaWindow != m_parentCocoaWindow)
                oldParentCocoaWindow->removeChildWindow(this);
            m_forwardWindow = oldParentCocoaWindow;
        }

        setNSWindow(m_nsWindow);
    }

    if (m_contentViewIsToBeEmbedded) {
        // An embedded window doesn't have its own NSWindow.
    } else if (!parentWindow) {
        // QPlatformWindow subclasses must sync up with QWindow on creation:
        propagateSizeHints();
        setWindowFlags(window()->flags());
        setWindowTitle(window()->title());
        setWindowState(window()->windowState());
    } else if (m_isNSWindowChild) {
        m_nsWindow.styleMask = NSBorderlessWindowMask;
        m_nsWindow.hasShadow = NO;
        m_nsWindow.level = NSNormalWindowLevel;
        NSWindowCollectionBehavior collectionBehavior =
                NSWindowCollectionBehaviorManaged | NSWindowCollectionBehaviorIgnoresCycle
                | NSWindowCollectionBehaviorFullScreenAuxiliary;
        m_nsWindow.animationBehavior = NSWindowAnimationBehaviorNone;
        m_nsWindow.collectionBehavior = collectionBehavior;
        setCocoaGeometry(windowGeometry());

        QList<QCocoaWindow *> &siblings = m_parentCocoaWindow->m_childWindows;
        if (siblings.contains(this)) {
            if (!m_hiddenByClipping)
                m_parentCocoaWindow->reinsertChildWindow(this);
        } else {
            if (!m_hiddenByClipping)
                [m_parentCocoaWindow->m_nsWindow addChildWindow:m_nsWindow ordered:NSWindowAbove];
            siblings.append(this);
        }
    } else {
        // Child windows have no NSWindow, link the NSViews instead.
        if ([contentView() superview])
            [contentView() removeFromSuperview];

        [m_parentCocoaWindow->contentView() addSubview : contentView()];
        QRect rect = windowGeometry();
        // Prevent setting a (0,0) window size; causes opengl context
        // "Invalid Drawable" warnings.
        if (rect.isNull())
            rect.setSize(QSize(1, 1));
        NSRect frame = NSMakeRect(rect.x(), rect.y(), rect.width(), rect.height());
        [contentView() setFrame:frame];
        [contentView() setHidden: YES];
    }

    m_nsWindow.ignoresMouseEvents =
        (window()->flags() & Qt::WindowTransparentForInput) == Qt::WindowTransparentForInput;

    const qreal opacity = qt_window_private(window())->opacity;
    if (!qFuzzyCompare(opacity, qreal(1.0)))
        setOpacity(opacity);

    // top-level QWindows may have an attached NSToolBar, call
    // update function which will attach to the NSWindow.
    if (!parentWindow)
        updateNSToolbar();
}

void QCocoaWindow::reinsertChildWindow(QCocoaWindow *child)
{
    int childIndex = m_childWindows.indexOf(child);
    Q_ASSERT(childIndex != -1);

    for (int i = childIndex; i < m_childWindows.size(); i++) {
        NSWindow *nsChild = m_childWindows[i]->nativeWindow();
        if (i != childIndex)
            [nativeWindow() removeChildWindow:nsChild];
        [nativeWindow() addChildWindow:nsChild ordered:NSWindowAbove];
    }
}

void QCocoaWindow::requestActivateWindow()
{
    NSWindow *window = [contentView() window];
    [ window makeFirstResponder : contentView() ];
    [ window makeKeyWindow ];
}

bool QCocoaWindow::shouldUseNSPanel()
{
    Qt::WindowType type = window()->type();

    return !m_isNSWindowChild &&
           ((type & Qt::Popup) == Qt::Popup || (type & Qt::Dialog) == Qt::Dialog);
}

QCocoaNSWindow * QCocoaWindow::createNSWindow()
{
    QMacAutoReleasePool pool;

    NSRect frame = qt_mac_flipRect(QPlatformWindow::geometry());

    Qt::WindowType type = window()->type();
    Qt::WindowFlags flags = window()->flags();

    NSUInteger styleMask;
    if (m_isNSWindowChild) {
        styleMask = NSBorderlessWindowMask;
    } else {
        styleMask = windowStyleMask(flags);
    }
    QCocoaNSWindow *createdWindow = 0;

    // Use NSPanel for popup-type windows. (Popup, Tool, ToolTip, SplashScreen)
    // and dialogs
    if (shouldUseNSPanel()) {
        QNSPanel *window;
        window  = [[QNSPanel alloc] initWithContentRect:frame
                                    styleMask: styleMask
                                    qPlatformWindow:this];
        if ((type & Qt::Popup) == Qt::Popup)
            [window setHasShadow:YES];

        // Qt::Tool windows hide on app deactivation, unless Qt::WA_MacAlwaysShowToolWindow is set.
        QVariant showWithoutActivating = QPlatformWindow::window()->property("_q_macAlwaysShowToolWindow");
        bool shouldHideOnDeactivate = ((type & Qt::Tool) == Qt::Tool) &&
                                      !(showWithoutActivating.isValid() && showWithoutActivating.toBool());
        [window setHidesOnDeactivate: shouldHideOnDeactivate];

        // Make popup windows show on the same desktop as the parent full-screen window.
        [window setCollectionBehavior:NSWindowCollectionBehaviorFullScreenAuxiliary];
        if ((type & Qt::Popup) == Qt::Popup)
            [window setAnimationBehavior:NSWindowAnimationBehaviorUtilityWindow];

        createdWindow = window;
    } else {
        QNSWindow *window;
        window  = [[QNSWindow alloc] initWithContentRect:frame
                                     styleMask: styleMask
                                     qPlatformWindow:this];
        createdWindow = window;
    }

    if ([createdWindow respondsToSelector:@selector(setRestorable:)])
        [createdWindow setRestorable: NO];

    NSInteger level = windowLevel(flags);
    [createdWindow setLevel:level];

    // OpenGL surfaces can be ordered either above(default) or below the NSWindow.
    // When ordering below the window must be tranclucent and have a clear background color.
    static GLint openglSourfaceOrder = qt_mac_resolveOption(1, "QT_MAC_OPENGL_SURFACE_ORDER");

    bool isTranslucent = window()->format().alphaBufferSize() > 0
                         || (surface()->supportsOpenGL() && openglSourfaceOrder == -1);
    if (isTranslucent) {
        [createdWindow setBackgroundColor:[NSColor clearColor]];
        [createdWindow setOpaque:NO];
    }

    m_windowModality = window()->modality();

    applyContentBorderThickness(createdWindow);

    return createdWindow;
}

void QCocoaWindow::setNSWindow(QCocoaNSWindow *window)
{
    if (window.contentView != contentView()) {
        [contentView() setPostsFrameChangedNotifications: NO];
        [contentView() retain];
        if (contentView().superview) // contentView() comes from another NSWindow
            [contentView() removeFromSuperview];
        [window setContentView:contentView()];
        [contentView() release];
        [contentView() setPostsFrameChangedNotifications: YES];
    }
}

void QCocoaWindow::removeChildWindow(QCocoaWindow *child)
{
    m_childWindows.removeOne(child);
    [nativeWindow() removeChildWindow:child->nativeWindow()];
}

void QCocoaWindow::removeMonitor()
{
    if (!monitor)
        return;
    [NSEvent removeMonitor:monitor];
    monitor = nil;
}

// Returns the current global screen geometry for the nswindow associated with this window.
QRect QCocoaWindow::nativeWindowGeometry() const
{
    if (!nativeWindow() || m_isNSWindowChild)
        return geometry();

    NSRect rect = [nativeWindow() frame];
    QPlatformScreen *onScreen = QPlatformScreen::platformScreenForWindow(window());
    int flippedY = onScreen->geometry().height() - rect.origin.y - rect.size.height;  // account for nswindow inverted y.
    QRect qRect = QRect(rect.origin.x, flippedY, rect.size.width, rect.size.height);
    return qRect;
}

// Returns a pointer to the parent QCocoaWindow for this window, or 0 if there is none.
QCocoaWindow *QCocoaWindow::parentCocoaWindow() const
{
    if (window() && window()->transientParent()) {
        return static_cast<QCocoaWindow*>(window()->transientParent()->handle());
    }
    return 0;
}

// Syncs the NSWindow minimize/maximize/fullscreen state with the current QWindow state
void QCocoaWindow::syncWindowState(Qt::WindowState newState)
{
    if (!nativeWindow())
        return;
    // if content view width or height is 0 then the window animations will crash so
    // do nothing except set the new state
    NSRect contentRect = [contentView() frame];
    if (contentRect.size.width <= 0 || contentRect.size.height <= 0) {
        qWarning("invalid window content view size, check your window geometry");
        m_synchedWindowState = newState;
        return;
    }

    Qt::WindowState predictedState = newState;
    if ((m_synchedWindowState & Qt::WindowMaximized) != (newState & Qt::WindowMaximized)) {
        const int styleMask = [nativeWindow() styleMask];
        const bool usePerform = styleMask & NSResizableWindowMask;
        [nativeWindow() setStyleMask:styleMask | NSResizableWindowMask];
        if (usePerform)
            [nativeWindow() performZoom : nativeWindow()]; // toggles
        else
            [nativeWindow() zoom : nativeWindow()]; // toggles
        [nativeWindow() setStyleMask:styleMask];
    }

    if ((m_synchedWindowState & Qt::WindowMinimized) != (newState & Qt::WindowMinimized)) {
        if (newState & Qt::WindowMinimized) {
            if ([nativeWindow() styleMask] & NSMiniaturizableWindowMask)
                [nativeWindow() performMiniaturize : nativeWindow()];
            else
                [nativeWindow() miniaturize : nativeWindow()];
        } else {
            [nativeWindow() deminiaturize : nativeWindow()];
        }
    }

    const bool effMax = m_effectivelyMaximized;
    if ((m_synchedWindowState & Qt::WindowMaximized) != (newState & Qt::WindowMaximized) || (m_effectivelyMaximized && newState == Qt::WindowNoState)) {
        if ((m_synchedWindowState & Qt::WindowFullScreen) == (newState & Qt::WindowFullScreen)) {
            [nativeWindow() zoom : nativeWindow()]; // toggles
            m_effectivelyMaximized = !effMax;
        } else if (!(newState & Qt::WindowMaximized)) {
            // it would be nice to change the target geometry that toggleFullScreen will animate toward
            // but there is no known way, so the maximized state is not possible at this time
            predictedState = static_cast<Qt::WindowState>(static_cast<int>(newState) | Qt::WindowMaximized);
            m_effectivelyMaximized = true;
        }
    }

    if ((m_synchedWindowState & Qt::WindowFullScreen) != (newState & Qt::WindowFullScreen)) {
        if (window()->flags() & Qt::WindowFullscreenButtonHint) {
            if (m_effectivelyMaximized && m_synchedWindowState == Qt::WindowFullScreen)
                predictedState = Qt::WindowMaximized;
            [nativeWindow() toggleFullScreen : nativeWindow()];
        } else {
            if (newState & Qt::WindowFullScreen) {
                QScreen *screen = window()->screen();
                if (screen) {
                    if (m_normalGeometry.width() < 0) {
                        m_oldWindowFlags = m_windowFlags;
                        window()->setFlags(window()->flags() | Qt::FramelessWindowHint);
                        m_normalGeometry = nativeWindowGeometry();
                        setGeometry(screen->geometry());
                        m_presentationOptions = [NSApp presentationOptions];
                        [NSApp setPresentationOptions : m_presentationOptions | NSApplicationPresentationAutoHideMenuBar | NSApplicationPresentationAutoHideDock];
                    }
                }
            } else {
                window()->setFlags(m_oldWindowFlags);
                setGeometry(m_normalGeometry);
                m_normalGeometry.setRect(0, 0, -1, -1);
                [NSApp setPresentationOptions : m_presentationOptions];
            }
        }
    }

    // New state is now the current synched state
    m_synchedWindowState = predictedState;
}

bool QCocoaWindow::setWindowModified(bool modified)
{
    if (!nativeWindow())
        return false;
    [nativeWindow() setDocumentEdited:(modified?YES:NO)];
    return true;
}

void QCocoaWindow::setMenubar(QCocoaMenuBar *mb)
{
    m_menubar = mb;
}

QCocoaMenuBar *QCocoaWindow::menubar() const
{
    return m_menubar;
}

void QCocoaWindow::setWindowCursor(NSCursor *cursor)
{
    // This function is called (via QCocoaCursor) by Qt to set
    // the cursor for this window. It can be called for a window
    // that is not currenly under the mouse pointer (for example
    // for a popup window.) Qt expects the set cursor to "stick":
    // it should be accociated with the window until a different
    // cursor is set.
    if (m_windowCursor != cursor) {
        [m_windowCursor release];
        m_windowCursor = [cursor retain];
    }

    // Use the built in cursor rect API if the QCocoaWindow has a NSWindow.
    // Othervise, set the cursor if this window is under the mouse. In
    // this case QNSView::cursorUpdate will set the cursor as the pointer
    // moves.
    if (nativeWindow() && qtView()) {
        [nativeWindow() invalidateCursorRectsForView : qtView()];
    } else {
        if (m_windowUnderMouse)
            [cursor set];
    }
}

void QCocoaWindow::registerTouch(bool enable)
{
    m_registerTouchCount += enable ? 1 : -1;
    if (enable && m_registerTouchCount == 1)
        [contentView() setAcceptsTouchEvents:YES];
    else if (m_registerTouchCount == 0)
        [contentView() setAcceptsTouchEvents:NO];
}

void QCocoaWindow::setContentBorderThickness(int topThickness, int bottomThickness)
{
    m_topContentBorderThickness = topThickness;
    m_bottomContentBorderThickness = bottomThickness;
    bool enable = (topThickness > 0 || bottomThickness > 0);
    m_drawContentBorderGradient = enable;

    applyContentBorderThickness(nativeWindow());
}

void QCocoaWindow::registerContentBorderArea(quintptr identifier, int upper, int lower)
{
    m_contentBorderAreas.insert(identifier, BorderRange(identifier, upper, lower));
    applyContentBorderThickness(nativeWindow());
}

void QCocoaWindow::setContentBorderAreaEnabled(quintptr identifier, bool enable)
{
    m_enabledContentBorderAreas.insert(identifier, enable);
    applyContentBorderThickness(nativeWindow());
}

void QCocoaWindow::setContentBorderEnabled(bool enable)
{
    m_drawContentBorderGradient = enable;
    applyContentBorderThickness(nativeWindow());
}

void QCocoaWindow::applyContentBorderThickness(NSWindow *window)
{
    if (!window)
        return;

    if (!m_drawContentBorderGradient) {
        [window setStyleMask:[window styleMask] & ~NSTexturedBackgroundWindowMask];
        [[[window contentView] superview] setNeedsDisplay:YES];
        return;
    }

    // Find consecutive registered border areas, starting from the top.
    QList<BorderRange> ranges = m_contentBorderAreas.values();
    std::sort(ranges.begin(), ranges.end());
    int effectiveTopContentBorderThickness = m_topContentBorderThickness;
    foreach (BorderRange range, ranges) {
        // Skip disiabled ranges (typically hidden tool bars)
        if (!m_enabledContentBorderAreas.value(range.identifier, false))
            continue;

        // Is this sub-range adjacent to or overlaping the
        // existing total border area range? If so merge
        // it into the total range,
        if (range.upper <= (effectiveTopContentBorderThickness + 1))
            effectiveTopContentBorderThickness = qMax(effectiveTopContentBorderThickness, range.lower);
        else
            break;
    }

    int effectiveBottomContentBorderThickness = m_bottomContentBorderThickness;

    [window setStyleMask:[window styleMask] | NSTexturedBackgroundWindowMask];

    [window setContentBorderThickness:effectiveTopContentBorderThickness forEdge:NSMaxYEdge];
    [window setAutorecalculatesContentBorderThickness:NO forEdge:NSMaxYEdge];

    [window setContentBorderThickness:effectiveBottomContentBorderThickness forEdge:NSMinYEdge];
    [window setAutorecalculatesContentBorderThickness:NO forEdge:NSMinYEdge];

    [[[window contentView] superview] setNeedsDisplay:YES];
}

void QCocoaWindow::updateNSToolbar()
{
    if (!nativeWindow())
        return;

    NSToolbar *toolbar = QCocoaIntegration::instance()->toolbar(window());

    if ([nativeWindow() toolbar] == toolbar)
       return;

    [nativeWindow() setToolbar: toolbar];
    [nativeWindow() setShowsToolbarButton:YES];
}

bool QCocoaWindow::testContentBorderAreaPosition(int position) const
{
    return nativeWindow() && m_drawContentBorderGradient &&
            0 <= position && position < [nativeWindow() contentBorderThicknessForEdge: NSMaxYEdge];
}

qreal QCocoaWindow::devicePixelRatio() const
{
    // The documented way to observe the relationship between device-independent
    // and device pixels is to use one for the convertToBacking functions. Other
    // methods such as [NSWindow backingScaleFacor] might not give the correct
    // result, for example if setWantsBestResolutionOpenGLSurface is not set or
    // or ignored by the OpenGL driver.
    NSSize backingSize = [contentView() convertSizeToBacking:NSMakeSize(1.0, 1.0)];
    return backingSize.height;
}

// Requests exposing the window. This is done via setNeedsDisplay/drawRect,
// but only if the window is not already exposed. The benefit of this is that
// no extra expose or paint events for already exposed window are generated.
void QCocoaWindow::requestExpose()
{
    if (m_exposedSize.isValid())
        return;
    [m_qtView setNeedsDisplay:YES];
}

// Updates the exposed state of a window by sending Expose events when
// window geometry or devicePixelRatio changes. Call this method with an
// empty rect on window hide.
bool QCocoaWindow::updateExposedState(QSize windowSize, const qreal devicePixelRatio)
{
    // Don't send expose events if there are no changes.
    if (m_exposedSize == windowSize && m_exposedDevicePixelRatio == devicePixelRatio)
        return false;

	qCDebug(lcQpaCocoaWindow) << "QCocoaWindow::updateExposedState" << window() << windowSize << devicePixelRatio;

    // Update the QWindow's screen property. This property is set
    // to QGuiApplication::primaryScreen() at QWindow construciton
    // time, and we won't get a NSWindowDidChangeScreenNotification
    // on show. The case where the window is initially displayed
    // on a non-primary screen needs special handling here.
    NSUInteger screenIndex = [[NSScreen screens] indexOfObject:nativeWindow().screen];
    if (screenIndex != NSNotFound) {
        QCocoaScreen *cocoaScreen = QCocoaIntegration::instance()->screenAtIndex(screenIndex);
        if (cocoaScreen)
            window()->setScreen(cocoaScreen->screen());
    }

    // Something changed, store the new geometry and send Expose event.
    m_exposedSize = windowSize;
    m_exposedDevicePixelRatio = devicePixelRatio;
    QWindowSystemInterface::handleExposeEvent(window(), QRect(QPoint(0,0), windowSize));

    // We want to produce a frame immediately on becomming visible or changing geometry
    if (!m_exposedSize.isEmpty())
        QWindowSystemInterface::flushWindowSystemEvents();
    return true;
}

QWindow *QCocoaWindow::childWindowAt(QPoint windowPoint)
{
    QWindow *targetWindow = window();
    foreach (QObject *child, targetWindow->children())
        if (QWindow *childWindow = qobject_cast<QWindow *>(child))
            if (QPlatformWindow *handle = childWindow->handle())
                if (handle->isExposed() && childWindow->geometry().contains(windowPoint))
                    targetWindow = static_cast<QCocoaWindow*>(handle)->childWindowAt(windowPoint - childWindow->position());

    return targetWindow;
}

bool QCocoaWindow::shouldRefuseKeyWindowAndFirstResponder()
{
    // This function speaks up if there's any reason
    // to refuse key window or first responder state.

    if (window()->flags() & Qt::WindowDoesNotAcceptFocus)
        return true;

    if (m_inSetVisible) {
        QVariant showWithoutActivating = window()->property("_q_showWithoutActivating");
        if (showWithoutActivating.isValid() && showWithoutActivating.toBool())
            return true;
    }

    return false;
}

QPoint QCocoaWindow::bottomLeftClippedByNSWindowOffsetStatic(QWindow *window)
{
    if (window->handle())
        return static_cast<QCocoaWindow *>(window->handle())->bottomLeftClippedByNSWindowOffset();
    return QPoint();
}

QPoint QCocoaWindow::bottomLeftClippedByNSWindowOffset() const
{
    if (!contentView())
        return QPoint();
    const NSPoint origin = [contentView() isFlipped] ? NSMakePoint(0, [contentView() frame].size.height)
                                                     : NSMakePoint(0,                                 0);
    const NSRect visibleRect = [contentView() visibleRect];

    return QPoint(visibleRect.origin.x, -visibleRect.origin.y + (origin.y - visibleRect.size.height));
}

NSView *QCocoaWindow::transferViewOwnershipStatic(QWindow *window)
{
    if (window->handle())
        return static_cast<QCocoaWindow *>(window->handle())->transferViewOwnership();
    return 0;
}

// Transfer ownership of the QNSView instance from the QCocoaWindow/QWindow instance to
// the caller, and also transfer ownership of the QWindow instance to the QNSView instance.
NSView *QCocoaWindow::transferViewOwnership()
{
    // Create the native view if needed.
    QNSView *view = qtView();

    // Already transfered? Return the view and do nothing.
    if (!m_ownsQtView)
        return view;

    // Check if the view actually is a QNSView and not foreign view.
    // Transferring ownership of the QWindow instance to a foreign view
    // does not make sense: a generic NSView has no idea what a QWindow is.
    if (!view) {
        qWarning("QCocoaWindow::transferViewOwnership: Could not transfer ownership to a non-QNSView");
        return 0;
    }

    // This function must be called instead of showing the window via the standard QWindow API.
    if (isExposed()) {
        qWarning("QCocoaWindow::transferViewOwnership: Could not transfer ownership of a visible window");
        return 0;
    }

    // Prepare the window for "embedded" mode.
    setEmbeddedInForeignView(true);

    // Normally, ~QCocoaWindow() deletes the QNSView instance. Set
    // ownership flags to prevent this and have [QNSView dealloc]
    // delete the QWindow (and QCocoaWindow) instead.
    m_ownsQtView = false;
    view->m_ownsQWindow = true;
    return view;
}

const CVTimeStamp *QCocoaWindow::displayLinkNowTimeStatic(QWindow *window)
{
    if (window->handle())
         return static_cast<QCocoaWindow *>(window->handle())->displayLinkNowTime();
    return nullptr;
}

const CVTimeStamp *QCocoaWindow::displayLinkNowTime() const
{
    if (!m_qtView)
        return 0;

    QMutexLocker lock(&m_qtView->m_displayLinkMutex);
    return m_qtView->m_displayLinkNowTime;
}

const CVTimeStamp *QCocoaWindow::displayLinkOutputTimeStatic(QWindow *window)
{
    if (window->handle())
         return static_cast<QCocoaWindow *>(window->handle())->displayLinkOutputTime();
    return nullptr;
}

const CVTimeStamp *QCocoaWindow::displayLinkOutputTime() const
{
    if (!m_qtView)
        return 0;

    QMutexLocker lock(&m_qtView->m_displayLinkMutex);
    return m_qtView->m_displayLinkOutputTime;
}

bool QCocoaWindow::inLayerMode() const
{
    return m_inLayerMode;
}

// Gets the current GL_DRAW_FRAMEBUFFER_BINDING for this window, which
// is set during the paint callback for QNSViews in OpenGL layer mode.
// Returns 0 othervise.
GLuint QCocoaWindow::defaultFramebufferObject() const
{
    if (!m_qtView)
        return 0;
    if (!m_inLayerMode)
        return 0;
    if (QCocoaGLLayer *layer = qcocoaopengllayer_cast([m_qtView layer]))
        return [layer drawFbo];
    return 0;
}

QMargins QCocoaWindow::frameMargins() const
{
    if (!m_nsWindow)
        return QMargins();

    NSRect frameW = [m_nsWindow frame];
    NSRect frameC = [m_nsWindow contentRectForFrameRect:frameW];

    return QMargins(frameW.origin.x - frameC.origin.x,
        (frameW.origin.y + frameW.size.height) - (frameC.origin.y + frameC.size.height),
        (frameW.origin.x + frameW.size.width) - (frameC.origin.x + frameC.size.width),
        frameC.origin.y - frameW.origin.y);
}

void QCocoaWindow::setFrameStrutEventsEnabled(bool enabled)
{
    m_frameStrutEventsEnabled = enabled;
}

void QCocoaWindow::requestUpdate()
{
    if (!window()->isVisible())
        return;
    [m_qtView requestUpdate];
}
void QCocoaWindow::requestUpdate(const QRect &rect)
{
    if (!window()->isVisible())
        return;
    [m_qtView requestUpdateWithRect:rect];
}

void QCocoaWindow::requestUpdate(const QRegion &region)
{
    if (!window()->isVisible())
        return;
    [m_qtView requestUpdateWithRegion:region];
}
