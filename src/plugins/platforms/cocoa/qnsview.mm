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

#include <QtCore/qglobal.h>

#include <QuartzCore/QuartzCore.h>
#include <dlfcn.h>

#include "qnsview.h"
#include "qcocoawindow.h"
#include "qcocoahelpers.h"
#include "qmultitouch_mac_p.h"
#include "qcocoadrag.h"
#include "qcocoainputcontext.h"
#include <qpa/qplatformintegration.h>

#include <qpa/qwindowsysteminterface.h>
#include <QtGui/QTextFormat>
#include <QtCore/QDebug>
#include <QtCore/qsysinfo.h>
#include <private/qguiapplication_p.h>
#include "qcocoabackingstore.h"
#ifndef QT_NO_OPENGL
#include "qcocoaglcontext.h"
#include "qcocoagllayer.h"
#include <QtGui/QOpenGLPaintDevice>
#endif
#include "qcocoaintegration.h"

#ifdef QT_COCOA_ENABLE_ACCESSIBILITY_INSPECTOR
#include <accessibilityinspector.h>
#endif

Q_LOGGING_CATEGORY(lcQpaTouch, "qt.qpa.input.touch")
#ifndef QT_NO_GESTURES
Q_LOGGING_CATEGORY(lcQpaGestures, "qt.qpa.input.gestures")
#endif
Q_LOGGING_CATEGORY(lcQpaTablet, "qt.qpa.input.tablet")

static QTouchDevice *touchDevice = 0;

// ### HACK Remove once 10.8 is unsupported
static NSString *_q_NSWindowDidChangeOcclusionStateNotification = nil;

static bool _q_dontOverrideCtrlLMB = false;

@interface NSEvent (Qt_Compile_Leopard_DeviceDelta)
  - (CGFloat)deviceDeltaX;
  - (CGFloat)deviceDeltaY;
  - (CGFloat)deviceDeltaZ;
@end

@interface QT_MANGLE_NAMESPACE(QNSViewMouseMoveHelper) : NSObject
{
    QNSView *view;
}

- (id)initWithView:(QNSView *)theView;

- (void)mouseMoved:(NSEvent *)theEvent;
- (void)mouseEntered:(NSEvent *)theEvent;
- (void)mouseExited:(NSEvent *)theEvent;
- (void)cursorUpdate:(NSEvent *)theEvent;

@end

@implementation QT_MANGLE_NAMESPACE(QNSViewMouseMoveHelper)

- (id)initWithView:(QNSView *)theView
{
    self = [super init];
    if (self) {
        view = theView;
    }
    return self;
}

- (void)mouseMoved:(NSEvent *)theEvent
{
    [view mouseMovedImpl:theEvent];
}

- (void)mouseEntered:(NSEvent *)theEvent
{
    [view mouseEnteredImpl:theEvent];
}

- (void)mouseExited:(NSEvent *)theEvent
{
    [view mouseExitedImpl:theEvent];
}

- (void)cursorUpdate:(NSEvent *)theEvent
{
    [view cursorUpdateImpl:theEvent];
}

@end

@implementation QT_MANGLE_NAMESPACE(QNSView)

+ (void)initialize
{
    NSString **notificationNameVar = (NSString **)dlsym(RTLD_NEXT, "NSWindowDidChangeOcclusionStateNotification");
    if (notificationNameVar)
        _q_NSWindowDidChangeOcclusionStateNotification = *notificationNameVar;

    _q_dontOverrideCtrlLMB = qt_mac_resolveOption(false, "QT_MAC_DONT_OVERRIDE_CTRL_LMB");
}

- (id) init
{
    self = [super initWithFrame : NSMakeRect(0,0, 300,300)];
    if (self) {
        m_backingStore = 0;
        m_maskImage = 0;
        m_shouldInvalidateWindowShadow = false;
        m_window = 0;
        m_buttons = Qt::NoButton;
        m_acceptedMouseDowns = Qt::NoButton;
        m_frameStrutButtons = Qt::NoButton;
        m_sendKeyEvent = false;
#ifndef QT_NO_OPENGL
        m_glContext = 0;
        m_shouldSetGLContextinDrawRect = false;
#endif
        currentCustomDragTypes = 0;
        m_sendUpAsRightButton = false;
        m_inputSource = 0;
        m_mouseMoveHelper = [[QT_MANGLE_NAMESPACE(QNSViewMouseMoveHelper) alloc] initWithView:self];
        m_resendKeyEvent = false;
        m_scrolling = false;
        m_updatingDrag = false;
        m_currentlyInterpretedKeyEvent = 0;
        m_inDrawRect = false;
        m_inFlushBackingStore = false;

        if (!touchDevice) {
            touchDevice = new QTouchDevice;
            touchDevice->setType(QTouchDevice::TouchPad);
            touchDevice->setCapabilities(QTouchDevice::Position | QTouchDevice::NormalizedPosition | QTouchDevice::MouseEmulation);
            QWindowSystemInterface::registerTouchDevice(touchDevice);
        }

        m_isMenuView = false;
        self.focusRingType = NSFocusRingTypeNone;
    }
    return self;
}

- (void)dealloc
{
    qCDebug(lcQpaCocoaWindow) << "[QNSView dealloc]" << m_window;

    if (m_ownsQWindow)
        delete m_window;
    m_window = 0;

    // Stop any running display link and the display link stop timer.
    [self destroyDisplayLink];

    // Remove any layer from the layer hiearchy to prevent AppKit from
    // trying to update it after the view has been deallocated.s
    [self.layer removeFromSuperlayer];

    CGImageRelease(m_maskImage);
    [m_trackingArea release];
    m_maskImage = 0;
    [m_inputSource release];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [m_mouseMoveHelper release];

    delete currentCustomDragTypes;

    [super dealloc];
}

CVReturn qNsViewDisplayLinkCallback(CVDisplayLinkRef displayLink, const CVTimeStamp* now, const CVTimeStamp* outputTime, CVOptionFlags flagsIn, CVOptionFlags* flagsOut, void* displayLinkContext);

- (id)initWithQWindow:(QWindow *)window platformWindow:(QCocoaWindow *) platformWindow
{
    self = [self init];
    if (!self)
        return 0;

    m_window = window;
    m_platformWindow = platformWindow;
    m_sendKeyEvent = false;
    m_trackingArea = nil;

    m_ownsQWindow = !m_platformWindow->m_ownsQtView;

    // Create DisplayLink if enabled.
    [self initializeDisplayLinkMembers];
    m_displayLinkEnable = qt_mac_resolveOption(false, "QT_MAC_ENABLE_CVDISPLAYLINK");
    if (m_displayLinkEnable)
        [self createDisplayLink];

#ifdef QT_COCOA_ENABLE_ACCESSIBILITY_INSPECTOR
    // prevent rift in space-time continuum, disable
    // accessibility for the accessibility inspector's windows.
    static bool skipAccessibilityForInspectorWindows = false;
    if (!skipAccessibilityForInspectorWindows) {

        // m_accessibleRoot = window->accessibleRoot();

        AccessibilityInspector *inspector = new AccessibilityInspector(window);
        skipAccessibilityForInspectorWindows = true;
        inspector->inspectWindow(window);
        skipAccessibilityForInspectorWindows = false;
    }
#endif

    [self registerDragTypes];
    [self setPostsFrameChangedNotifications : YES];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                          selector:@selector(updateGeometry)
                                          name:NSViewFrameDidChangeNotification
                                          object:self];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                          selector:@selector(textInputContextKeyboardSelectionDidChangeNotification:)
                                          name:NSTextInputContextKeyboardSelectionDidChangeNotification
                                          object:nil];

    return self;
}

#ifndef QT_NO_OPENGL
- (CALayer *)makeBackingLayer
{
    // This function is called if layer mode is active, which can
    // happen if this view requests a layer, or if a parent view
    // requests a layer.


    // possibly Use IOSurface + layer for QWindow::OpenGLSurface
    if (m_window->surfaceType() == QWindow::OpenGLSurface) {
        static bool useCustomLayer = qt_mac_resolveOption(true, "QT_MAC_USE_OPENGL_IOSURFACE");

        m_platformWindow->m_inIOSurfaceMode = true;
        m_platformWindow->m_inCustomLayerMode = true;

        // ### Using the default NSView layer and setting the layer contents
        // seems to work, expect that the layer contents appear flipped. Infortunately
        // setting the geometryFlipped property does not work.

        // CALayer *layer = [[CALayer alloc] init];
        CALayer *layer = [super makeBackingLayer];
        //layer.geometryFlipped = YES;
        return layer;
    }


    // Possibly use a custom OpenGL layer for QWindow::OpenGLSurface
    if (m_window->surfaceType() == QWindow::OpenGLSurface) {
        static bool useCustomLayer = qt_mac_resolveOption(true, "QT_MAC_USE_OPENGL_SURFACE_CUSTOM_LAYER");
        if (useCustomLayer) {
            m_platformWindow->m_inCustomLayerMode = true;
            return [[QCocoaGLLayer alloc] initWithQNSView:self andQCocoaWindow:m_platformWindow];
        }
    }

    // Possibly use a custom OpenGL layer for QWindow::RasterGLSurface.
    // This surface type must handle both raster and GL content.
    if (m_window->surfaceType() == QWindow::RasterGLSurface) {
        static bool useCustomLayer = qt_mac_resolveOption(false, "QT_MAC_USE_RASTERGL_SURFACE_CUSTOM_LAYER");
        if (useCustomLayer) {
            m_platformWindow->m_inCustomLayerMode = true;
            return [[QCocoaGLLayer alloc] initWithQNSView:self andQCocoaWindow:m_platformWindow];
        }
    }

    // QWindow::RasterSurface updates may possibly also happen directly on
    // on the layer. This does not require a custom layer and as controlled
    // with QT_MAC_USE_RASTER_SURFACE_DIRECT_UPDATE which sets QCocoaWindow::m_useRasterLayerUpdate.

    // Fall back to using the default layer if no custom layer has been created.
    return [super makeBackingLayer];
}
#endif

- (void) clearQWindowPointers
{
    m_window = 0;
    m_platformWindow = 0;
}

#ifndef QT_NO_OPENGL
- (void) setQCocoaGLContext:(QCocoaGLContext *)context
{
    m_glContext = context;
    [m_glContext->nativeContext() setView:self];
    if (![m_glContext->nativeContext() view]) {
        //was unable to set view
        m_shouldSetGLContextinDrawRect = true;
    }
}
#endif

- (void)viewDidMoveToSuperview
{
    if (!(m_platformWindow->m_contentViewIsToBeEmbedded))
        return;

    if ([self superview]) {
        m_platformWindow->m_contentViewIsEmbedded = true;
        QWindowSystemInterface::handleGeometryChange(m_window, m_platformWindow->geometry());
    } else {
        m_platformWindow->m_contentViewIsEmbedded = false;
    }
}

- (void)viewWillMoveToWindow:(NSWindow *)newWindow
{
    // ### Merge "normal" window code path with this one for 5.1.
    if (!(m_window->type() & Qt::SubWindow))
        return;

    if (newWindow) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(windowNotification:)
                                              name:nil // Get all notifications
                                              object:newWindow];
    }
    if ([self window])
        [[NSNotificationCenter defaultCenter] removeObserver:self name:nil object:[self window]];
}

- (QWindow *)topLevelWindow
{
    QWindow *focusWindow = m_window;

    // For widgets we need to do a bit of trickery as the window
    // to activate is the window of the top-level widget.
    if (qstrcmp(m_window->metaObject()->className(), "QWidgetWindow") == 0) {
        while (focusWindow->parent()) {
            focusWindow = focusWindow->parent();
        }
    }

    return focusWindow;
}

// Called when native view geometry has changed. The native view/window has the
// new geometry, this function updates QPlatformWindow::geometry and sends a
// GeometryChange event to Qt.
- (void)updateGeometry
{
    // Don't react to geometry updates during QCocoaWindow construction. Shuffling the NSViews and
    // NSWindows into place may generate spurious geometry updates. There should be no real updates
    // here: we want the native geometry to be the geometry determined by the QCocoaWindow constructor.
    if (m_platformWindow->m_inConstructor)
        return;

    // It can happen that self.window is nil (if we are changing
    // styleMask from/to borderless and content view is being re-parented)
    // - this results in an invalid coordinates.
    if (m_platformWindow->m_inSetStyleMask && !self.window)
        return;

    // Child NSWindow windows are special-cased (see QCocoaWindow::setCocoaGeometry)
    if (m_platformWindow->m_isNSWindowChild)
        return;

    // Fetch (new) native geometry. Use NSWindow geometry if there is one, else use
    // NSView geometry.
    QRect newGeometry;
    NSWindow *nativeWindow = m_platformWindow->m_nsWindow;
    if (nativeWindow) {
        // Get interior (content) geometry in the Qt coordinate system
        newGeometry = qt_mac_flipRect([nativeWindow contentRectForFrameRect:[nativeWindow frame]]);
    } else {
        // QNSView is isFLipped, no qt_mac_flipRect needed.
        newGeometry = qt_mac_toQRect([self frame]);
    }

    // Note difference below:
    //   QPlatformWindow::geometry(): the actual native geometry
    //   QCocoaWindow::geometry(): native geometry as reported to Qt
    // This is much ado about a little detail: Qt thinks that embedded QWindows
    // are top-level windows and expects global coordinates - while they
    // are actually not. QPlatformWindow::geometry reflects the true native
    // geometry in this case (but with the Qt origin-top-left)

    // Stop if the geometry has not actually changed.
    if (newGeometry == m_platformWindow->QPlatformWindow::geometry())
        return;

    qCDebug(lcQpaCocoaWindow) << "[QNSView udpateGeometry:]" << m_window
                              << "current" << m_platformWindow->geometry() << "new" << newGeometry;

    // Store new geometry and notify Qt of the change
    m_platformWindow->QPlatformWindow::setGeometry(newGeometry);
    QWindowSystemInterface::handleGeometryChange(m_window, m_platformWindow->QCocoaWindow::geometry());
}

- (void)notifyWindowStateChanged:(Qt::WindowState)newState
{
    // If the window was maximized, then fullscreen, then tried to go directly to "normal" state,
    // this notification will say that it is "normal", but it will still look maximized, and
    // if you called performZoom it would actually take it back to "normal".
    // So we should say that it is maximized because it actually is.
    if (newState == Qt::WindowNoState && m_platformWindow->m_effectivelyMaximized)
        newState = Qt::WindowMaximized;
    QWindowSystemInterface::handleWindowStateChanged(m_window, newState);
    // We want to read the window state back from the window,
    // but the event we just sent may be asynchronous.
    QWindowSystemInterface::flushWindowSystemEvents();
    m_platformWindow->setSynchedWindowStateFromWindow();
}

- (void)windowNotification : (NSNotification *) windowNotification
{
    //qDebug() << "windowNotification" << QCFString::toQString([windowNotification name]);

    NSString *notificationName = [windowNotification name];
    if (notificationName == NSWindowDidBecomeKeyNotification) {
        if (!m_platformWindow->windowIsPopupType() && !m_isMenuView)
            QWindowSystemInterface::handleWindowActivated(m_window);
    } else if (notificationName == NSWindowDidResignKeyNotification) {
        // key window will be non-nil if another window became key... do not
        // set the active window to zero here, the new key window's
        // NSWindowDidBecomeKeyNotification hander will change the active window
        NSWindow *keyWindow = [NSApp keyWindow];
        if (!keyWindow || keyWindow == windowNotification.object) {
            // no new key window, go ahead and set the active window to zero
            if (!m_platformWindow->windowIsPopupType() && !m_isMenuView)
                QWindowSystemInterface::handleWindowActivated(0);
        }
    } else if (notificationName == NSWindowDidMiniaturizeNotification
               || notificationName == NSWindowDidDeminiaturizeNotification) {
        Qt::WindowState newState = notificationName == NSWindowDidMiniaturizeNotification ?
                    Qt::WindowMinimized : Qt::WindowNoState;
        [self notifyWindowStateChanged:newState];

    } else if (_q_NSWindowDidChangeOcclusionStateNotification
               && [notificationName isEqualToString:_q_NSWindowDidChangeOcclusionStateNotification]) {
        if (([self.window occlusionState] & NSWindowOcclusionStateVisible) == 0) {
            m_platformWindow->updateExposedState(QSize());
        } else {
            m_platformWindow->requestExpose();
        }

    } else if (notificationName == NSWindowDidChangeScreenNotification) {

        // Update displaylink display to match the new screen.
        NSScreen *screen = self.window.screen;
        NSNumber *screenNumber = [[screen deviceDescription] objectForKey:@"NSScreenNumber"];
        CGDirectDisplayID screenDisplayID = (CGDirectDisplayID) [screenNumber intValue];
        CVDisplayLinkSetCurrentCGDisplay(m_displayLink, screenDisplayID);

        // Send screen change notification to Qt
        if (m_window) {
            NSUInteger screenIndex = [[NSScreen screens] indexOfObject:self.window.screen];
            if (screenIndex != NSNotFound) {
                QCocoaScreen *cocoaScreen = QCocoaIntegration::instance()->screenAtIndex(screenIndex);
                QWindowSystemInterface::handleWindowScreenChanged(m_window, cocoaScreen->screen());
            }
        }
    } else if (notificationName == NSWindowDidEnterFullScreenNotification
               || notificationName == NSWindowDidExitFullScreenNotification) {
        Qt::WindowState newState = notificationName == NSWindowDidEnterFullScreenNotification ?
                                   Qt::WindowFullScreen : Qt::WindowNoState;
        [self notifyWindowStateChanged:newState];
    }
}

- (void)textInputContextKeyboardSelectionDidChangeNotification : (NSNotification *) textInputContextKeyboardSelectionDidChangeNotification
{
    Q_UNUSED(textInputContextKeyboardSelectionDidChangeNotification)
    if (([NSApp keyWindow] == [self window]) && [[self window] firstResponder] == self) {
        QCocoaInputContext *ic = qobject_cast<QCocoaInputContext *>(QCocoaIntegration::instance()->inputContext());
        ic->updateLocale();
    }
}

- (void)notifyWindowWillZoom:(BOOL)willZoom
{
    Qt::WindowState newState = willZoom ? Qt::WindowMaximized : Qt::WindowNoState;
    if (!willZoom)
        m_platformWindow->m_effectivelyMaximized = false;
    [self notifyWindowStateChanged:newState];
}

- (void)viewDidHide
{
    m_platformWindow->updateExposedState(QSize());
}

- (void)removeFromSuperview
{
    QMacAutoReleasePool pool;
    [super removeFromSuperview];
}

- (void) flushBackingStore:(QCocoaBackingStore *)backingStore region:(const QRegion &)region offset:(QPoint)offset
{
    m_backingStore = backingStore;
    m_backingStoreOffset = offset * m_backingStore->getBackingStoreDevicePixelRatio();

    // Standard Qt behavior requires that backing store flush should be synchronous,
    // so the expected behavior here is to immediately flush the backing store content
    // to the QNSView. However, if this flush is being called as a result of a paint
    // request from [drawRect:] then we are done - there is a displyIfNeeded in progress
    // and we don't want to trigger a new one. This is the "good", performant code path.
    if (m_inDrawRect)
        return;

    // Let Cocoa handle updates during window resizing.
    if (self.inLiveResize)
        return;

    // If not trigger a drawRect call by invalidating the view and triggering a
    // synchrounous redraw. This code path will be triggered if/when Qt or the
    // application flushes the backing store outside of UpdateRequest or ExposeEvent
    // callbacks. This code path is susceptible to performance issues if flush is
    // called more often than ~60 times per second.
    bool inLayerMode = ([self layer] != 0);
    bool usesCustomOpenGLLayer = (inLayerMode && m_window->supportsOpenGL());
    bool usesRasterLayerUpdate = m_platformWindow->m_useRasterLayerUpdate;
    if (inLayerMode && usesCustomOpenGLLayer) {
        // OpenGL layer mode is async
    } else if (inLayerMode && usesRasterLayerUpdate) {
        [self.layer setNeedsDisplay];
    } else {
        m_inFlushBackingStore = true;

        // Invalidate and repaint the updated region.
        foreach (QRect rect, region.rects())
            [self setNeedsDisplayInRect:NSMakeRect(rect.x(), rect.y(), rect.width(), rect.height())];
        [self displayIfNeeded];

        // Core Animation layer mode needs a flush call to propagate the new
        // content to the window. (This is normally done automatically when
        // spinning the event loop). This is may also be needed on newer
        // versions of macOS.
        if (inLayerMode || QSysInfo::MacintoshVersion > QSysInfo::MV_10_11)
            [CATransaction flush];

        m_inFlushBackingStore = false;
    }
}

- (void)clearBackingStore:(QCocoaBackingStore *)backingStore
{
    if (backingStore == m_backingStore)
        m_backingStore = 0;
}

- (BOOL) hasMask
{
    return !m_maskRegion.isEmpty();
}

- (BOOL) isOpaque
{
    if (!m_platformWindow)
        return true;
    return m_platformWindow->isOpaque();
}

- (void) setMaskRegion:(const QRegion *)region
{
    m_maskRegion = *region;

    m_shouldInvalidateWindowShadow = true;
    m_maskRegion = *region;
    if (m_maskImage)
        CGImageRelease(m_maskImage);
    if (region->isEmpty()) {
        m_maskImage = 0;
        return;
    }

    const QRect &rect = region->boundingRect();
    QImage tmp(rect.size(), QImage::Format_RGB32);
    tmp.fill(Qt::white);
    QPainter p(&tmp);
    p.setClipRegion(*region);
    p.fillRect(rect, Qt::black);
    p.end();
    QImage maskImage = QImage(rect.size(), QImage::Format_Indexed8);
    for (int y=0; y<rect.height(); ++y) {
        const uint *src = (const uint *) tmp.constScanLine(y);
        uchar *dst = maskImage.scanLine(y);
        for (int x=0; x<rect.width(); ++x) {
            dst[x] = src[x] & 0xff;
        }
    }
    m_maskImage = qt_mac_toCGImageMask(maskImage);
}

- (void)invalidateWindowShadowIfNeeded
{
    if (!m_shouldInvalidateWindowShadow)
        return;

    if (NSWindow *window = m_platformWindow->nativeWindow()) {
        [window invalidateShadow];
        m_shouldInvalidateWindowShadow = false;
    }
}

-(BOOL) wantsUpdateLayer
{
    return m_platformWindow->m_useRasterLayerUpdate || m_platformWindow->m_inIOSurfaceMode;
}

- (void) updateLayer
{
    [self sendUpdateRequest];

    if (m_platformWindow->m_useRasterLayerUpdate) {
        // Set the layer contents to be the backing store image
        if (m_backingStore)
            self.layer.contents = (__bridge id) qt_mac_toCGImage(m_backingStore->toImage());
    }
}

- (void) drawRect:(NSRect)dirtyRect
{
    qCDebug(lcQpaCocoaWindow) << "[QNSView drawRect:]" << m_window << qt_mac_toQRect(dirtyRect);

    QBoolBlocker inDrawRect(m_inDrawRect);

#ifndef QT_NO_OPENGL
    if (m_glContext && m_shouldSetGLContextinDrawRect) {
        [m_glContext->nativeContext() setView:self];
        m_shouldSetGLContextinDrawRect = false;
    }
#endif

    // Draw window background for the unified tool bar.
    if (m_platformWindow->m_drawContentBorderGradient)
        NSDrawWindowBackground(dirtyRect);

    // qDebug() << "drawRect window type" << m_window->supportsOpenGL();

    // Request a frame from Qt. This is a synchronous call, where Qt
    // should draw and flush before returning. The excepton is if
    // this [drawRect:] call was itself triggered by a backingstore
    // flush; in that case there already is new/up to date backingstore
    // content.
    if (!m_inFlushBackingStore)
        [self sendUpdateRequest];

    // Now draw the backing store
    bool usesCustomOpenGLLayer = (m_platformWindow->m_inCustomLayerMode && m_window->supportsOpenGL());
    if (!usesCustomOpenGLLayer)
        [self drawBackingStoreUsingCoreGraphics:dirtyRect];

    [self invalidateWindowShadowIfNeeded];
}

// Draws the backing store content to the QNSView using Core Graphcis.
// This function assumes that the QNSView is in a configuration that
// supports Core Graphics, such as non-layer mode or layer mode with
// the default layer. In particular, using this function with a QCocoaGLLayer
// backed view won't work.
- (void) drawBackingStoreUsingCoreGraphics:(NSRect)dirtyRect
{
    if (!m_backingStore)
        return;

    // Calculate source and target rects. The target rect is the dirtyRect:
    CGRect dirtyWindowRect = NSRectToCGRect(dirtyRect);

    // The backing store source rect will be larger on retina displays.
    // Scale dirtyRect by the device pixel ratio:
    const qreal devicePixelRatio = m_backingStore->getBackingStoreDevicePixelRatio();
    CGRect dirtyBackingRect = CGRectMake(dirtyRect.origin.x * devicePixelRatio,
                                         dirtyRect.origin.y * devicePixelRatio,
                                         dirtyRect.size.width * devicePixelRatio,
                                         dirtyRect.size.height * devicePixelRatio);

    NSGraphicsContext *nsGraphicsContext = [NSGraphicsContext currentContext];
    CGContextRef cgContext = (CGContextRef) [nsGraphicsContext graphicsPort];

    // Translate coordiate system from CoreGraphics (bottom-left) to NSView (top-left):
    CGContextSaveGState(cgContext);
    int dy = dirtyWindowRect.origin.y + CGRectGetMaxY(dirtyWindowRect);

    CGContextTranslateCTM(cgContext, 0, dy);
    CGContextScaleCTM(cgContext, 1, -1);

    // If a mask is set, modify the sub image accordingly:
    CGImageRef subMask = 0;
    if (m_maskImage) {
        subMask = CGImageCreateWithImageInRect(m_maskImage, dirtyWindowRect);
        CGContextClipToMask(cgContext, dirtyWindowRect, subMask);
    }

    // Clip out and draw the correct sub image from the (shared) backingstore:
    CGRect backingStoreRect = CGRectMake(
        dirtyBackingRect.origin.x + m_backingStoreOffset.x(),
        dirtyBackingRect.origin.y + m_backingStoreOffset.y(),
        dirtyBackingRect.size.width,
        dirtyBackingRect.size.height
    );
    CGImageRef bsCGImage = qt_mac_toCGImage(m_backingStore->toImage());
    CGImageRef cleanImg = CGImageCreateWithImageInRect(bsCGImage, backingStoreRect);

    // Optimization: Copy frame buffer content instead of blending for
    // top-level windows where Qt fills the entire window content area.
    // (But don't overpaint the title-bar gradient)
    if (m_platformWindow->nativeWindow() && !m_platformWindow->m_drawContentBorderGradient)
        CGContextSetBlendMode(cgContext, kCGBlendModeCopy);

    CGContextDrawImage(cgContext, dirtyWindowRect, cleanImg);

    // Clean-up:
    CGContextRestoreGState(cgContext);
    CGImageRelease(cleanImg);
    CGImageRelease(subMask);
    CGImageRelease(bsCGImage);
}

// Draws the backing store using an QOpenGLPaintDevice. This
// function assumes that there is a current OpengGL context.
- (void) drawBackingStoreUsingQOpenGL
{
    if (!m_backingStore)
        return;

    QImage backingStoreImage = m_backingStore->toImage();

    glClearColor(1.0, 0.5, 0.5, 1.0);
    glClear(GL_COLOR_BUFFER_BIT);

    // TODO: draw backingStoreImage on GL context - but how?
    // Using QOpenGLPaintDevice gives a dependency inversion where
    // the platform plugin depends on QtGui

    // QOpenGLPaintDevice glDevice;
    // glDevice.setSize(backingStoreImage.size());
    // QPainter p(&glDevice);
    // p.drawImage(QPoint(0, 0), backingStoreImage);
}

- (BOOL) isFlipped
{
    return YES;
}

- (BOOL)becomeFirstResponder
{
    if (m_window && (m_window->flags() & Qt::WindowTransparentForInput) )
        return NO;
    if (!m_platformWindow->windowIsPopupType() && !m_isMenuView)
        QWindowSystemInterface::handleWindowActivated([self topLevelWindow]);
    return YES;
}

- (BOOL)acceptsFirstResponder
{
    if (m_isMenuView)
        return NO;
    if (m_platformWindow->shouldRefuseKeyWindowAndFirstResponder())
        return NO;
    if (m_window && (m_window->flags() & Qt::WindowTransparentForInput) )
        return NO;
    if ((m_window->flags() & Qt::ToolTip) == Qt::ToolTip)
        return NO;
    return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)theEvent
{
    Q_UNUSED(theEvent)
    if (m_window && (m_window->flags() & Qt::WindowTransparentForInput) )
        return NO;
    return YES;
}

- (NSView *)hitTest:(NSPoint)aPoint
{
    NSView *candidate = [super hitTest:aPoint];
    if (candidate == self) {
        if (m_window && (m_window->flags() & Qt::WindowTransparentForInput))
            return nil;
    }
    return candidate;
}

- (void)convertFromScreen:(NSPoint)mouseLocation toWindowPoint:(QPointF *)qtWindowPoint andScreenPoint:(QPointF *)qtScreenPoint
{
    // Calculate the mouse position in the QWindow and Qt screen coordinate system,
    // starting from coordinates in the NSWindow coordinate system.
    //
    // This involves translating according to the window location on screen,
    // as well as inverting the y coordinate due to the origin change.
    //
    // Coordinate system overview, outer to innermost:
    //
    // Name             Origin
    //
    // OS X screen      bottom-left
    // Qt screen        top-left
    // NSWindow         bottom-left
    // NSView/QWindow   top-left
    //
    // NSView and QWindow are equal coordinate systems: the QWindow covers the
    // entire NSView, and we've set the NSView's isFlipped property to true.

    NSWindow *window = [self window];
    NSPoint nsWindowPoint;
    NSRect windowRect = [window convertRectFromScreen:NSMakeRect(mouseLocation.x, mouseLocation.y, 1, 1)];
    nsWindowPoint = windowRect.origin;                    // NSWindow coordinates
    NSPoint nsViewPoint = [self convertPoint: nsWindowPoint fromView: nil]; // NSView/QWindow coordinates
    *qtWindowPoint = QPointF(nsViewPoint.x, nsViewPoint.y);                     // NSView/QWindow coordinates

    *qtScreenPoint = QPointF(mouseLocation.x, qt_mac_flipYCoordinate(mouseLocation.y)); // Qt screen coordinates
}

- (void)resetMouseButtons
{
    m_buttons = Qt::NoButton;
    m_frameStrutButtons = Qt::NoButton;
}

- (NSPoint) screenMousePoint:(NSEvent *)theEvent
{
    NSPoint screenPoint;
    if (theEvent) {
        NSPoint windowPoint = [theEvent locationInWindow];
        NSRect screenRect = [[theEvent window] convertRectToScreen:NSMakeRect(windowPoint.x, windowPoint.y, 1, 1)];
        screenPoint = screenRect.origin;
    } else {
        screenPoint = [NSEvent mouseLocation];
    }
    return screenPoint;
}

- (void)handleMouseEvent:(NSEvent *)theEvent
{
    bool isTabletEvent = [self handleTabletEvent: theEvent];

    QNSView *targetView = self;
    if (m_platformWindow && m_platformWindow->m_forwardWindow) {
        if (theEvent.type == NSLeftMouseDragged || theEvent.type == NSLeftMouseUp)
            targetView = m_platformWindow->m_forwardWindow->m_qtView;
        else
            m_platformWindow->m_forwardWindow = 0;
    }

    // Popups implicitly grap mouse events; forward to the active popup if there is one
    if (QCocoaWindow *popup = QCocoaIntegration::instance()->activePopupWindow()) {
        // Tooltips must be transparent for mouse events
        // The bug reference is QTBUG-46379
        if (!popup->m_windowFlags.testFlag(Qt::ToolTip)) {
            if (QNSView *popupView = popup->qtView())
                targetView = popupView;
        }
    }

    QPointF qtWindowPoint;
    QPointF qtScreenPoint;
    [targetView convertFromScreen:[self screenMousePoint:theEvent] toWindowPoint:&qtWindowPoint andScreenPoint:&qtScreenPoint];
    ulong timestamp = [theEvent timestamp] * 1000;

    QCocoaDrag* nativeDrag = QCocoaIntegration::instance()->drag();
    nativeDrag->setLastMouseEvent(theEvent, self);
    Qt::KeyboardModifiers keyboardModifiers = [QNSView convertKeyModifiers:[theEvent modifierFlags]];
    QWindowSystemInterface::handleMouseEvent(targetView->m_window, timestamp, qtWindowPoint, qtScreenPoint, m_buttons, keyboardModifiers,
                                             isTabletEvent ? Qt::MouseEventSynthesizedByQt : Qt::MouseEventNotSynthesized);
}

- (bool)handleMouseDownEvent:(NSEvent *)theEvent
{
    if (m_window && (m_window->flags() & Qt::WindowTransparentForInput))
        return false;

    Qt::MouseButton button = cocoaButton2QtButton([theEvent buttonNumber]);

    QPointF qtWindowPoint;
    QPointF qtScreenPoint;
    [self convertFromScreen:[self screenMousePoint:theEvent] toWindowPoint:&qtWindowPoint andScreenPoint:&qtScreenPoint];
    Q_UNUSED(qtScreenPoint);

    // Maintain masked state for the button for use by MouseDragged and MouseUp.
    const bool masked = [self hasMask] && !m_maskRegion.contains(qtWindowPoint.toPoint());
    if (masked)
        m_acceptedMouseDowns &= ~button;
    else
        m_acceptedMouseDowns |= button;

    // Forward masked out events to the next responder
    if (masked)
        return false;

    if (button == Qt::RightButton)
        m_sendUpAsRightButton = true;

    m_buttons |= button;

    [self handleMouseEvent:theEvent];
    return true;
}

- (bool)handleMouseDraggedEvent:(NSEvent *)theEvent
{
    if (m_window && (m_window->flags() & Qt::WindowTransparentForInput))
        return false;

    Qt::MouseButton button = cocoaButton2QtButton([theEvent buttonNumber]);

    // Forward the event to the next responder if Qt did not accept the
    // corresponding mouse down for this button
    if (!(m_acceptedMouseDowns & button) == button)
        return false;

    if (!(m_buttons & (m_sendUpAsRightButton ? Qt::RightButton : Qt::LeftButton))) {
        qCWarning(lcQpaCocoaWindow) << "QNSView mouseDragged: Internal mouse button tracking"
                                    << "invalid (missing Qt::LeftButton)";
    }

    [self handleMouseEvent:theEvent];
    return true;
}

- (bool)handleMouseUpEvent:(NSEvent *)theEvent
{
    if (m_window && (m_window->flags() & Qt::WindowTransparentForInput))
        return false;

    Qt::MouseButton button = cocoaButton2QtButton([theEvent buttonNumber]);

    // Forward the event to the next responder if Qt did not accept the
    // corresponding mouse down for this button
    if (!(m_acceptedMouseDowns & button) == button)
        return false;

    if (m_sendUpAsRightButton && button == Qt::LeftButton)
        button = Qt::RightButton;
    if (button == Qt::RightButton)
        m_sendUpAsRightButton = false;

    m_buttons &= ~button;

    [self handleMouseEvent:theEvent];
    return true;
}

- (void)mouseDown:(NSEvent *)theEvent
{
    if (m_window && (m_window->flags() & Qt::WindowTransparentForInput)) {
        [super mouseDown:theEvent];
        return;
    }

    m_sendUpAsRightButton = false;

    // Handle any active poup windows; clicking outisde them should close them
    // all. Don't do anything or clicks inside one of the menus, let Cocoa
    // handle that case. Note that in practice many windows of the Qt::Popup type
    // will actually close themselves in this case using logic implemented in
    // that particular poup type (for example context menus). However, Qt expects
    // that plain popup QWindows will also be closed, so we implement the logic
    // here as well.
    QList<QCocoaWindow *> *popups = QCocoaIntegration::instance()->popupWindowStack();
    if (!popups->isEmpty()) {
        // Check if the click is outside all popups.
        bool inside = false;
        QPointF qtScreenPoint = qt_mac_flipPoint([self screenMousePoint:theEvent]);
        for (QList<QCocoaWindow *>::const_iterator it = popups->begin(); it != popups->end(); ++it) {
            if ((*it)->geometry().contains(qtScreenPoint.toPoint())) {
                inside = true;
                break;
            }
        }
        // Close the popups if the click was outside.
        if (!inside) {
            Qt::WindowType type = QCocoaIntegration::instance()->activePopupWindow()->window()->type();
            while (QCocoaWindow *popup = QCocoaIntegration::instance()->popPopupWindow()) {
                QWindowSystemInterface::handleCloseEvent(popup->window());
                QWindowSystemInterface::flushWindowSystemEvents();
            }
            // Consume the mouse event when closing the popup, except for tool tips
            // were it's expected that the event is processed normally.
            if (type != Qt::ToolTip)
                 return;
        }
    }

    QPointF qtWindowPoint;
    QPointF qtScreenPoint;
    [self convertFromScreen:[self screenMousePoint:theEvent] toWindowPoint:&qtWindowPoint andScreenPoint:&qtScreenPoint];
    Q_UNUSED(qtScreenPoint);

    const bool masked = [self hasMask] && !m_maskRegion.contains(qtWindowPoint.toPoint());

    // Maintain masked state for the button for use by MouseDragged and Up.
    if (masked)
        m_acceptedMouseDowns &= ~Qt::LeftButton;
    else
        m_acceptedMouseDowns |= Qt::LeftButton;

    // Forward masked out events to the next responder
    if (masked) {
        [super mouseDown:theEvent];
        return;
    }

    if ([self hasMarkedText]) {
        [[NSTextInputContext currentInputContext] handleEvent:theEvent];
    } else {
        if (!_q_dontOverrideCtrlLMB && [QNSView convertKeyModifiers:[theEvent modifierFlags]] & Qt::MetaModifier) {
            m_buttons |= Qt::RightButton;
            m_sendUpAsRightButton = true;
        } else {
            m_buttons |= Qt::LeftButton;
        }

        [self handleMouseEvent:theEvent];
    }
}

- (void)mouseDragged:(NSEvent *)theEvent
{
    const bool accepted = [self handleMouseDraggedEvent:theEvent];
    if (!accepted)
        [super mouseDragged:theEvent];
}

- (void)mouseUp:(NSEvent *)theEvent
{
    const bool accepted = [self handleMouseUpEvent:theEvent];
    if (!accepted)
        [super mouseUp:theEvent];
}

- (void)rightMouseDown:(NSEvent *)theEvent
{
    const bool accepted = [self handleMouseDownEvent:theEvent];
    if (!accepted)
        [super rightMouseDown:theEvent];
}

- (void)rightMouseDragged:(NSEvent *)theEvent
{
    const bool accepted = [self handleMouseDraggedEvent:theEvent];
    if (!accepted)
        [super rightMouseDragged:theEvent];
}

- (void)rightMouseUp:(NSEvent *)theEvent
{
    const bool accepted = [self handleMouseUpEvent:theEvent];
    if (!accepted)
        [super rightMouseUp:theEvent];
}

- (void)otherMouseDown:(NSEvent *)theEvent
{
    const bool accepted = [self handleMouseDownEvent:theEvent];
    if (!accepted)
        [super otherMouseDown:theEvent];
}

- (void)otherMouseDragged:(NSEvent *)theEvent
{
    const bool accepted = [self handleMouseDraggedEvent:theEvent];
    if (!accepted)
        [super otherMouseDragged:theEvent];
}

- (void)otherMouseUp:(NSEvent *)theEvent
{
    const bool accepted = [self handleMouseUpEvent:theEvent];
    if (!accepted)
        [super otherMouseUp:theEvent];
}

- (void)handleFrameStrutMouseEvent:(NSEvent *)theEvent
{
    // get m_buttons in sync
    // Don't send frme strut events if we are in the middle of a mouse drag.
    if (m_buttons != Qt::NoButton)
        return;

    NSEventType ty = [theEvent type];
    switch (ty) {
    case NSLeftMouseDown:
        m_frameStrutButtons |= Qt::LeftButton;
        break;
    case NSLeftMouseUp:
         m_frameStrutButtons &= ~Qt::LeftButton;
         break;
    case NSRightMouseDown:
        m_frameStrutButtons |= Qt::RightButton;
        break;
    case NSLeftMouseDragged:
        m_frameStrutButtons |= Qt::LeftButton;
        break;
    case NSRightMouseDragged:
        m_frameStrutButtons |= Qt::RightButton;
        break;
    case NSRightMouseUp:
        m_frameStrutButtons &= ~Qt::RightButton;
        break;
    case NSOtherMouseDown:
        m_frameStrutButtons |= cocoaButton2QtButton([theEvent buttonNumber]);
        break;
    case NSOtherMouseUp:
        m_frameStrutButtons &= ~cocoaButton2QtButton([theEvent buttonNumber]);
    default:
        break;
    }

    NSWindow *window = [self window];
    NSPoint windowPoint = [theEvent locationInWindow];

    int windowScreenY = [window frame].origin.y + [window frame].size.height;
    NSPoint windowCoord = [self convertPoint:[self frame].origin toView:nil];
    int viewScreenY = [window convertRectToScreen:NSMakeRect(windowCoord.x, windowCoord.y, 0, 0)].origin.y;
    int titleBarHeight = windowScreenY - viewScreenY;

    NSPoint nsViewPoint = [self convertPoint: windowPoint fromView: nil];
    QPoint qtWindowPoint = QPoint(nsViewPoint.x, titleBarHeight + nsViewPoint.y);
    NSPoint screenPoint = [window convertRectToScreen:NSMakeRect(windowPoint.x, windowPoint.y, 0, 0)].origin;
    QPoint qtScreenPoint = QPoint(screenPoint.x, qt_mac_flipYCoordinate(screenPoint.y));

    ulong timestamp = [theEvent timestamp] * 1000;
    QWindowSystemInterface::handleFrameStrutMouseEvent(m_window, timestamp, qtWindowPoint, qtScreenPoint, m_frameStrutButtons);
}

- (void)updateTrackingAreas
{
    [super updateTrackingAreas];

    QMacAutoReleasePool pool;

    // NSTrackingInVisibleRect keeps care of updating once the tracking is set up, so bail out early
    if (m_trackingArea && [[self trackingAreas] containsObject:m_trackingArea])
        return;

    // Ideally, we shouldn't have NSTrackingMouseMoved events included below, it should
    // only be turned on if mouseTracking, hover is on or a tool tip is set.
    // Unfortunately, Qt will send "tooltip" events on mouse moves, so we need to
    // turn it on in ALL case. That means EVERY QWindow gets to pay the cost of
    // mouse moves delivered to it (Apple recommends keeping it OFF because there
    // is a performance hit). So it goes.
    NSUInteger trackingOptions = NSTrackingMouseEnteredAndExited | NSTrackingActiveInActiveApp
                                 | NSTrackingInVisibleRect | NSTrackingMouseMoved | NSTrackingCursorUpdate;
    [m_trackingArea release];
    m_trackingArea = [[NSTrackingArea alloc] initWithRect:[self frame]
                                                  options:trackingOptions
                                                    owner:m_mouseMoveHelper
                                                 userInfo:nil];
    [self addTrackingArea:m_trackingArea];
}

-(void)cursorUpdateImpl:(NSEvent *)theEvent
{
    Q_UNUSED(theEvent)
    // Set the cursor manually if there is no NSWindow.
    if (!m_platformWindow->nativeWindow() && m_platformWindow->m_windowCursor)
        [m_platformWindow->m_windowCursor set];
    else
        [super cursorUpdate:theEvent];
}

-(void)resetCursorRects
{
    // Use the cursor rect API if there is a NSWindow
    if (m_platformWindow->nativeWindow() && m_platformWindow->m_windowCursor)
        [self addCursorRect:[self visibleRect] cursor:m_platformWindow->m_windowCursor];
}

- (void)mouseMovedImpl:(NSEvent *)theEvent
{
    if (m_window && (m_window->flags() & Qt::WindowTransparentForInput) )
        return;

    QPointF windowPoint;
    QPointF screenPoint;
    [self convertFromScreen:[self screenMousePoint:theEvent] toWindowPoint:&windowPoint andScreenPoint:&screenPoint];
    QWindow *childWindow = m_platformWindow->childWindowAt(windowPoint.toPoint());

    // Top-level windows generate enter-leave events for sub-windows.
    // Qt wants to know which window (if any) will be entered at the
    // the time of the leave. This is dificult to accomplish by
    // handling mouseEnter and mouseLeave envents, since they are sent
    // individually to different views.
    if (m_platformWindow->nativeWindow() && childWindow) {
        if (childWindow != m_platformWindow->m_enterLeaveTargetWindow) {
            QWindowSystemInterface::handleEnterLeaveEvent(childWindow, m_platformWindow->m_enterLeaveTargetWindow, windowPoint, screenPoint);
            m_platformWindow->m_enterLeaveTargetWindow = childWindow;
        }
    }

    // Cocoa keeps firing mouse move events for obscured parent views. Qt should not
    // send those events so filter them out here.
    if (childWindow != m_window)
        return;

    [self handleMouseEvent: theEvent];
}

- (void)mouseEnteredImpl:(NSEvent *)theEvent
{
    Q_UNUSED(theEvent)
    m_platformWindow->m_windowUnderMouse = true;

    if (m_window && (m_window->flags() & Qt::WindowTransparentForInput) )
        return;

    // Top-level windows generate enter events for sub-windows.
    if (!m_platformWindow->nativeWindow())
        return;

    QPointF windowPoint;
    QPointF screenPoint;
    [self convertFromScreen:[NSEvent mouseLocation] toWindowPoint:&windowPoint andScreenPoint:&screenPoint];
    m_platformWindow->m_enterLeaveTargetWindow = m_platformWindow->childWindowAt(windowPoint.toPoint());
    QWindowSystemInterface::handleEnterEvent(m_platformWindow->m_enterLeaveTargetWindow, windowPoint, screenPoint);
}

- (void)mouseExitedImpl:(NSEvent *)theEvent
{
    Q_UNUSED(theEvent);
    m_platformWindow->m_windowUnderMouse = false;

    if (m_window && (m_window->flags() & Qt::WindowTransparentForInput) )
        return;

    // Top-level windows generate leave events for sub-windows.
    if (!m_platformWindow->nativeWindow())
        return;

    QWindowSystemInterface::handleLeaveEvent(m_platformWindow->m_enterLeaveTargetWindow);
    m_platformWindow->m_enterLeaveTargetWindow = 0;
}

struct QCocoaTabletDeviceData
{
    QTabletEvent::TabletDevice device;
    QTabletEvent::PointerType pointerType;
    uint capabilityMask;
    qint64 uid;
};

typedef QHash<uint, QCocoaTabletDeviceData> QCocoaTabletDeviceDataHash;
Q_GLOBAL_STATIC(QCocoaTabletDeviceDataHash, tabletDeviceDataHash)

- (bool)handleTabletEvent: (NSEvent *)theEvent
{
    NSEventType eventType = [theEvent type];
    if (eventType != NSTabletPoint && [theEvent subtype] != NSTabletPointEventSubtype)
        return false; // Not a tablet event.

    ulong timestamp = [theEvent timestamp] * 1000;

    QPointF windowPoint;
    QPointF screenPoint;
    [self convertFromScreen:[NSEvent mouseLocation] toWindowPoint: &windowPoint andScreenPoint: &screenPoint];

    uint deviceId = [theEvent deviceID];
    if (!tabletDeviceDataHash->contains(deviceId)) {
        // Error: Unknown tablet device. Qt also gets into this state
        // when running on a VM. This appears to be harmless; don't
        // print a warning.
        return false;
    }
    const QCocoaTabletDeviceData &deviceData = tabletDeviceDataHash->value(deviceId);

    bool down = (eventType != NSMouseMoved);

    qreal pressure;
    if (down) {
        pressure = [theEvent pressure];
    } else {
        pressure = 0.0;
    }

    NSPoint tilt = [theEvent tilt];
    int xTilt = qRound(tilt.x * 60.0);
    int yTilt = qRound(tilt.y * -60.0);
    Qt::MouseButtons buttons = static_cast<Qt::MouseButtons>(static_cast<uint>([theEvent buttonMask]));
    qreal tangentialPressure = 0;
    qreal rotation = 0;
    int z = 0;
    if (deviceData.capabilityMask & 0x0200)
        z = [theEvent absoluteZ];

    if (deviceData.capabilityMask & 0x0800)
        tangentialPressure = ([theEvent tangentialPressure] * 2.0) - 1.0;

    rotation = 360.0 - [theEvent rotation];
    if (rotation > 180.0)
        rotation -= 360.0;

    Qt::KeyboardModifiers keyboardModifiers = [QNSView convertKeyModifiers:[theEvent modifierFlags]];

    qCDebug(lcQpaTablet, "event on tablet %d with tool %d type %d unique ID %lld pos %6.1f, %6.1f root pos %6.1f, %6.1f buttons 0x%x pressure %4.2lf tilt %d, %d rotation %6.2lf",
        deviceId, deviceData.device, deviceData.pointerType, deviceData.uid,
        windowPoint.x(), windowPoint.y(), screenPoint.x(), screenPoint.y(),
        static_cast<uint>(buttons), pressure, xTilt, yTilt, rotation);

    QWindowSystemInterface::handleTabletEvent(m_window, timestamp, windowPoint, screenPoint,
                                              deviceData.device, deviceData.pointerType, buttons, pressure, xTilt, yTilt,
                                              tangentialPressure, rotation, z, deviceData.uid,
                                              keyboardModifiers);
    return true;
}

- (void)tabletPoint: (NSEvent *)theEvent
{
    if (m_window && (m_window->flags() & Qt::WindowTransparentForInput) )
        return [super tabletPoint:theEvent];

    [self handleTabletEvent: theEvent];
}

static QTabletEvent::TabletDevice wacomTabletDevice(NSEvent *theEvent)
{
    qint64 uid = [theEvent uniqueID];
    uint bits = [theEvent vendorPointingDeviceType];
    if (bits == 0 && uid != 0) {
        // Fallback. It seems that the driver doesn't always include all the information.
        // High-End Wacom devices store their "type" in the uper bits of the Unique ID.
        // I'm not sure how to handle it for consumer devices, but I'll test that in a bit.
        bits = uid >> 32;
    }

    QTabletEvent::TabletDevice device;
    // Defined in the "EN0056-NxtGenImpGuideX"
    // on Wacom's Developer Website (www.wacomeng.com)
    if (((bits & 0x0006) == 0x0002) && ((bits & 0x0F06) != 0x0902)) {
        device = QTabletEvent::Stylus;
    } else {
        switch (bits & 0x0F06) {
            case 0x0802:
                device = QTabletEvent::Stylus;
                break;
            case 0x0902:
                device = QTabletEvent::Airbrush;
                break;
            case 0x0004:
                device = QTabletEvent::FourDMouse;
                break;
            case 0x0006:
                device = QTabletEvent::Puck;
                break;
            case 0x0804:
                device = QTabletEvent::RotationStylus;
                break;
            default:
                device = QTabletEvent::NoDevice;
        }
    }
    return device;
}

- (void)tabletProximity: (NSEvent *)theEvent
{
    if (m_window && (m_window->flags() & Qt::WindowTransparentForInput) )
        return [super tabletProximity:theEvent];

    ulong timestamp = [theEvent timestamp] * 1000;

    QCocoaTabletDeviceData deviceData;
    deviceData.uid = [theEvent uniqueID];
    deviceData.capabilityMask = [theEvent capabilityMask];

    switch ([theEvent pointingDeviceType]) {
        case NSUnknownPointingDevice:
        default:
            deviceData.pointerType = QTabletEvent::UnknownPointer;
            break;
        case NSPenPointingDevice:
            deviceData.pointerType = QTabletEvent::Pen;
            break;
        case NSCursorPointingDevice:
            deviceData.pointerType = QTabletEvent::Cursor;
            break;
        case NSEraserPointingDevice:
            deviceData.pointerType = QTabletEvent::Eraser;
            break;
    }

    deviceData.device = wacomTabletDevice(theEvent);

    // The deviceID is "unique" while in the proximity, it's a key that we can use for
    // linking up QCocoaTabletDeviceData to an event (especially if there are two devices in action).
    bool entering = [theEvent isEnteringProximity];
    uint deviceId = [theEvent deviceID];
    if (entering) {
        tabletDeviceDataHash->insert(deviceId, deviceData);
    } else {
        tabletDeviceDataHash->remove(deviceId);
    }

    qCDebug(lcQpaTablet, "proximity change on tablet %d: current tool %d type %d unique ID %lld",
        deviceId, deviceData.device, deviceData.pointerType, deviceData.uid);

    if (entering) {
        QWindowSystemInterface::handleTabletEnterProximityEvent(timestamp, deviceData.device, deviceData.pointerType, deviceData.uid);
    } else {
        QWindowSystemInterface::handleTabletLeaveProximityEvent(timestamp, deviceData.device, deviceData.pointerType, deviceData.uid);
    }
}

- (bool) shouldSendSingleTouch
{
    // QtWidgets expects single-point touch events, QtDeclarative does not.
    // Until there is an API we solve this by looking at the window class type.
    return m_window->inherits("QWidgetWindow");
}

- (void)touchesBeganWithEvent:(NSEvent *)event
{
    const NSTimeInterval timestamp = [event timestamp];
    const QList<QWindowSystemInterface::TouchPoint> points = QCocoaTouch::getCurrentTouchPointList(event, [self shouldSendSingleTouch]);
    qCDebug(lcQpaTouch) << "touchesBeganWithEvent" << points;
    QWindowSystemInterface::handleTouchEvent(m_window, timestamp * 1000, touchDevice, points);
}

- (void)touchesMovedWithEvent:(NSEvent *)event
{
    const NSTimeInterval timestamp = [event timestamp];
    const QList<QWindowSystemInterface::TouchPoint> points = QCocoaTouch::getCurrentTouchPointList(event, [self shouldSendSingleTouch]);
    qCDebug(lcQpaTouch) << "touchesMovedWithEvent" << points;
    QWindowSystemInterface::handleTouchEvent(m_window, timestamp * 1000, touchDevice, points);
}

- (void)touchesEndedWithEvent:(NSEvent *)event
{
    const NSTimeInterval timestamp = [event timestamp];
    const QList<QWindowSystemInterface::TouchPoint> points = QCocoaTouch::getCurrentTouchPointList(event, [self shouldSendSingleTouch]);
    qCDebug(lcQpaTouch) << "touchesEndedWithEvent" << points;
    QWindowSystemInterface::handleTouchEvent(m_window, timestamp * 1000, touchDevice, points);
}

- (void)touchesCancelledWithEvent:(NSEvent *)event
{
    const NSTimeInterval timestamp = [event timestamp];
    const QList<QWindowSystemInterface::TouchPoint> points = QCocoaTouch::getCurrentTouchPointList(event, [self shouldSendSingleTouch]);
    qCDebug(lcQpaTouch) << "touchesCancelledWithEvent" << points;
    QWindowSystemInterface::handleTouchEvent(m_window, timestamp * 1000, touchDevice, points);
}

#ifndef QT_NO_GESTURES

- (bool)handleGestureAsBeginEnd:(NSEvent *)event
{
    if (QSysInfo::QSysInfo::MacintoshVersion < QSysInfo::MV_10_11)
        return false;

    if ([event phase] == NSEventPhaseBegan) {
        [self beginGestureWithEvent:event];
        return true;
    }

    if ([event phase] == NSEventPhaseEnded) {
        [self endGestureWithEvent:event];
        return true;
    }

    return false;
}
- (void)magnifyWithEvent:(NSEvent *)event
{
    if ([self handleGestureAsBeginEnd:event])
        return;

    qCDebug(lcQpaGestures) << "magnifyWithEvent" << [event magnification];
    const NSTimeInterval timestamp = [event timestamp];
    QPointF windowPoint;
    QPointF screenPoint;
    [self convertFromScreen:[NSEvent mouseLocation] toWindowPoint:&windowPoint andScreenPoint:&screenPoint];
    QWindowSystemInterface::handleGestureEventWithRealValue(m_window, timestamp, Qt::ZoomNativeGesture,
                                                            [event magnification], windowPoint, screenPoint);
}

#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_8
- (void)smartMagnifyWithEvent:(NSEvent *)event
{
    static bool zoomIn = true;
    qCDebug(lcQpaGestures) << "smartMagnifyWithEvent" << zoomIn;
    const NSTimeInterval timestamp = [event timestamp];
    QPointF windowPoint;
    QPointF screenPoint;
    [self convertFromScreen:[NSEvent mouseLocation] toWindowPoint:&windowPoint andScreenPoint:&screenPoint];
    QWindowSystemInterface::handleGestureEventWithRealValue(m_window, timestamp, Qt::SmartZoomNativeGesture,
                                                            zoomIn ? 1.0f : 0.0f, windowPoint, screenPoint);
    zoomIn = !zoomIn;
}
#endif

- (void)rotateWithEvent:(NSEvent *)event
{
    if ([self handleGestureAsBeginEnd:event])
        return;

    const NSTimeInterval timestamp = [event timestamp];
    QPointF windowPoint;
    QPointF screenPoint;
    [self convertFromScreen:[NSEvent mouseLocation] toWindowPoint:&windowPoint andScreenPoint:&screenPoint];
    QWindowSystemInterface::handleGestureEventWithRealValue(m_window, timestamp, Qt::RotateNativeGesture,
                                                            -[event rotation], windowPoint, screenPoint);
}

- (void)swipeWithEvent:(NSEvent *)event
{
    qCDebug(lcQpaGestures) << "swipeWithEvent" << [event deltaX] << [event deltaY];
    const NSTimeInterval timestamp = [event timestamp];
    QPointF windowPoint;
    QPointF screenPoint;
    [self convertFromScreen:[NSEvent mouseLocation] toWindowPoint:&windowPoint andScreenPoint:&screenPoint];

    qreal angle = 0.0f;
    if ([event deltaX] == 1)
        angle = 180.0f;
    else if ([event deltaX] == -1)
        angle = 0.0f;
    else if ([event deltaY] == 1)
        angle = 90.0f;
    else if ([event deltaY] == -1)
        angle = 270.0f;

    QWindowSystemInterface::handleGestureEventWithRealValue(m_window, timestamp, Qt::SwipeNativeGesture,
                                                            angle, windowPoint, screenPoint);
}

- (void)beginGestureWithEvent:(NSEvent *)event
{
    const NSTimeInterval timestamp = [event timestamp];
    QPointF windowPoint;
    QPointF screenPoint;
    [self convertFromScreen:[NSEvent mouseLocation] toWindowPoint:&windowPoint andScreenPoint:&screenPoint];
    qCDebug(lcQpaGestures) << "beginGestureWithEvent @" << windowPoint;
    QWindowSystemInterface::handleGestureEvent(m_window, timestamp, Qt::BeginNativeGesture,
                                               windowPoint, screenPoint);
}

- (void)endGestureWithEvent:(NSEvent *)event
{
    qCDebug(lcQpaGestures) << "endGestureWithEvent";
    const NSTimeInterval timestamp = [event timestamp];
    QPointF windowPoint;
    QPointF screenPoint;
    [self convertFromScreen:[NSEvent mouseLocation] toWindowPoint:&windowPoint andScreenPoint:&screenPoint];
    QWindowSystemInterface::handleGestureEvent(m_window, timestamp, Qt::EndNativeGesture,
                                               windowPoint, screenPoint);
}
#endif // QT_NO_GESTURES

#ifndef QT_NO_WHEELEVENT
- (void)scrollWheel:(NSEvent *)theEvent
{
    if (m_window && (m_window->flags() & Qt::WindowTransparentForInput) )
        return [super scrollWheel:theEvent];

    QPoint angleDelta;
    Qt::MouseEventSource source = Qt::MouseEventNotSynthesized;
    if ([theEvent hasPreciseScrollingDeltas]) {
        // The mouse device contains pixel scroll wheel support (Mighty Mouse, Trackpad).
        // Since deviceDelta is delivered as pixels rather than degrees, we need to
        // convert from pixels to degrees in a sensible manner.
        // It looks like 1/4 degrees per pixel behaves most native.
        // (NB: Qt expects the unit for delta to be 8 per degree):
        const int pixelsToDegrees = 2; // 8 * 1/4
        angleDelta.setX([theEvent scrollingDeltaX] * pixelsToDegrees);
        angleDelta.setY([theEvent scrollingDeltaY] * pixelsToDegrees);
        source = Qt::MouseEventSynthesizedBySystem;
    } else {
        // Remove acceleration, and use either -120 or 120 as delta:
        angleDelta.setX(qBound(-120, int([theEvent deltaX] * 10000), 120));
        angleDelta.setY(qBound(-120, int([theEvent deltaY] * 10000), 120));
    }

    QPoint pixelDelta;
    if ([theEvent hasPreciseScrollingDeltas]) {
        pixelDelta.setX([theEvent scrollingDeltaX]);
        pixelDelta.setY([theEvent scrollingDeltaY]);
    } else {
        // docs: "In the case of !hasPreciseScrollingDeltas, multiply the delta with the line width."
        // scrollingDeltaX seems to return a minimum value of 0.1 in this case, map that to two pixels.
        const CGFloat lineWithEstimate = 20.0;
        pixelDelta.setX([theEvent scrollingDeltaX] * lineWithEstimate);
        pixelDelta.setY([theEvent scrollingDeltaY] * lineWithEstimate);
    }

    QPointF qt_windowPoint;
    QPointF qt_screenPoint;
    [self convertFromScreen:[NSEvent mouseLocation] toWindowPoint:&qt_windowPoint andScreenPoint:&qt_screenPoint];
    NSTimeInterval timestamp = [theEvent timestamp];
    ulong qt_timestamp = timestamp * 1000;

    // Prevent keyboard modifier state from changing during scroll event streams.
    // A two-finger trackpad flick generates a stream of scroll events. We want
    // the keyboard modifier state to be the state at the beginning of the
    // flick in order to avoid changing the interpretation of the events
    // mid-stream. One example of this happening would be when pressing cmd
    // after scrolling in Qt Creator: not taking the phase into account causes
    // the end of the event stream to be interpreted as font size changes.
    NSEventPhase momentumPhase = [theEvent momentumPhase];
    if (momentumPhase == NSEventPhaseNone) {
        currentWheelModifiers = [QNSView convertKeyModifiers:[theEvent modifierFlags]];
    }

    NSEventPhase phase = [theEvent phase];
    Qt::ScrollPhase ph = Qt::ScrollUpdate;
#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_8
    if (QSysInfo::QSysInfo::MacintoshVersion >= QSysInfo::MV_10_8) {
        // On 10.8 and above, MayBegin is likely to happen.  We treat it the same as an actual begin.
        if (phase == NSEventPhaseMayBegin) {
            m_scrolling = true;
            ph = Qt::ScrollBegin;
        }
    }
#endif
    if (phase == NSEventPhaseBegan) {
        // If MayBegin did not happen, Began is the actual beginning.
        if (!m_scrolling)
            ph = Qt::ScrollBegin;
        m_scrolling = true;
    } else if (phase == NSEventPhaseEnded || phase == NSEventPhaseCancelled ||
               momentumPhase == NSEventPhaseEnded || momentumPhase == NSEventPhaseCancelled) {
        ph = Qt::ScrollEnd;
        m_scrolling = false;
    } else if (phase == NSEventPhaseNone && momentumPhase == NSEventPhaseNone) {
        ph = Qt::NoScrollPhase;
    }
    // "isInverted": natural OS X scrolling, inverted from the Qt/other platform/Jens perspective.
    bool isInverted  = [theEvent isDirectionInvertedFromDevice];

    QWindowSystemInterface::handleWheelEvent(m_window, qt_timestamp, qt_windowPoint, qt_screenPoint, pixelDelta, angleDelta, currentWheelModifiers, ph, source, isInverted);
}
#endif //QT_NO_WHEELEVENT

- (int) convertKeyCode : (QChar)keyChar
{
    return qt_mac_cocoaKey2QtKey(keyChar);
}

+ (Qt::KeyboardModifiers) convertKeyModifiers : (ulong)modifierFlags
{
    Qt::KeyboardModifiers qtMods =Qt::NoModifier;
    if (modifierFlags &  NSShiftKeyMask)
        qtMods |= Qt::ShiftModifier;
    if (modifierFlags & NSControlKeyMask)
        qtMods |= Qt::MetaModifier;
    if (modifierFlags & NSAlternateKeyMask)
        qtMods |= Qt::AltModifier;
    if (modifierFlags & NSCommandKeyMask)
        qtMods |= Qt::ControlModifier;
    if (modifierFlags & NSNumericPadKeyMask)
        qtMods |= Qt::KeypadModifier;
    return qtMods;
}

- (bool)handleKeyEvent:(NSEvent *)nsevent eventType:(int)eventType
{
    ulong timestamp = [nsevent timestamp] * 1000;
    ulong nativeModifiers = [nsevent modifierFlags];
    Qt::KeyboardModifiers modifiers = [QNSView convertKeyModifiers: nativeModifiers];
    NSString *charactersIgnoringModifiers = [nsevent charactersIgnoringModifiers];
    NSString *characters = [nsevent characters];
    if (m_inputSource != characters) {
        [m_inputSource release];
        m_inputSource = [characters retain];
    }

    // There is no way to get the scan code from carbon/cocoa. But we cannot
    // use the value 0, since it indicates that the event originates from somewhere
    // else than the keyboard.
    quint32 nativeScanCode = 1;
    quint32 nativeVirtualKey = [nsevent keyCode];

    QChar ch = QChar::ReplacementCharacter;
    int keyCode = Qt::Key_unknown;
    if ([characters length] != 0) {
        if (((modifiers & Qt::MetaModifier) || (modifiers & Qt::AltModifier)) && ([charactersIgnoringModifiers length] != 0))
            ch = QChar([charactersIgnoringModifiers characterAtIndex:0]);
        else
            ch = QChar([characters characterAtIndex:0]);
        keyCode = [self convertKeyCode:ch];
    }

    // we will send a key event unless the input method sets m_sendKeyEvent to false
    m_sendKeyEvent = true;
    QString text;
    // ignore text for the U+F700-U+F8FF range. This is used by Cocoa when
    // delivering function keys (e.g. arrow keys, backspace, F1-F35, etc.)
    if (!(modifiers & (Qt::ControlModifier | Qt::MetaModifier)) && (ch.unicode() < 0xf700 || ch.unicode() > 0xf8ff))
        text = QCFString::toQString(characters);

    QWindow *window = [self topLevelWindow];

    // Popups implicitly grab key events; forward to the active popup if there is one.
    // This allows popups to e.g. intercept shortcuts and close the popup in response.
    if (QCocoaWindow *popup = QCocoaIntegration::instance()->activePopupWindow()) {
        if (!popup->m_windowFlags.testFlag(Qt::ToolTip))
            window = popup->window();
    }

    if (eventType == QEvent::KeyPress) {

        if (m_composingText.isEmpty()) {
            m_sendKeyEvent = !QWindowSystemInterface::handleShortcutEvent(window, timestamp, keyCode,
                modifiers, nativeScanCode, nativeVirtualKey, nativeModifiers, text, [nsevent isARepeat], 1);
        }

        QObject *fo = QGuiApplication::focusObject();
        if (m_sendKeyEvent && fo) {
            QInputMethodQueryEvent queryEvent(Qt::ImEnabled | Qt::ImHints);
            if (QCoreApplication::sendEvent(fo, &queryEvent)) {
                bool imEnabled = queryEvent.value(Qt::ImEnabled).toBool();
                Qt::InputMethodHints hints = static_cast<Qt::InputMethodHints>(queryEvent.value(Qt::ImHints).toUInt());
                if (imEnabled && !(hints & Qt::ImhDigitsOnly || hints & Qt::ImhFormattedNumbersOnly || hints & Qt::ImhHiddenText)) {
                    // pass the key event to the input method. note that m_sendKeyEvent may be set to false during this call
                    m_currentlyInterpretedKeyEvent = nsevent;
                    [self interpretKeyEvents:[NSArray arrayWithObject:nsevent]];
                    m_currentlyInterpretedKeyEvent = 0;
                }
            }
        }
        if (m_resendKeyEvent)
            m_sendKeyEvent = true;
    }

    bool accepted = true;
    if (m_sendKeyEvent && m_composingText.isEmpty()) {
        QWindowSystemInterface::handleExtendedKeyEvent(window, timestamp, QEvent::Type(eventType), keyCode, modifiers,
                                                       nativeScanCode, nativeVirtualKey, nativeModifiers, text, [nsevent isARepeat], 1, false);
        accepted = QWindowSystemInterface::flushWindowSystemEvents();
    }
    m_sendKeyEvent = false;
    m_resendKeyEvent = false;
    return accepted;
}

- (void)keyDown:(NSEvent *)nsevent
{
    if (m_window && (m_window->flags() & Qt::WindowTransparentForInput) ) {
        [super keyDown:nsevent];
        return;
    }
    bool accepted = [self handleKeyEvent:nsevent eventType:int(QEvent::KeyPress)];

    // Track keyDown acceptance state for later acceptance of the keyUp.
    if (accepted)
        m_acceptedKeyDowns.insert([nsevent keyCode]);

    // Propagate the keyDown to the next responder if Qt did not accept it.
    if (!accepted)
        [super keyDown:nsevent];
}

- (void)keyUp:(NSEvent *)nsevent
{
    if (m_window && (m_window->flags() & Qt::WindowTransparentForInput) )
        return [super keyUp:nsevent];

    const bool keyUpAccepted = [self handleKeyEvent:nsevent eventType:int(QEvent::KeyRelease)];

    // Propagate the keyUp if neither Qt accepted it nor the corresponding KeyDown was
    // accepted. Qt text controls wil often not use and ignore keyUp events, but we
    // want to avoid propagating unmatched keyUps.
    const bool keyDownAccepted = m_acceptedKeyDowns.remove([nsevent keyCode]);
    if (!keyUpAccepted && !keyDownAccepted)
        [super keyUp:nsevent];
}

- (void)cancelOperation:(id)sender
{
    Q_UNUSED(sender);

    NSEvent *currentEvent = [NSApp currentEvent];
    if (!currentEvent || currentEvent.type != NSKeyDown)
        return;

    // Handling the key event may recurse back here through interpretKeyEvents
    // (when IM is enabled), so we need to guard against that.
    if (currentEvent == m_currentlyInterpretedKeyEvent)
        return;

    // Send Command+Key_Period and Escape as normal keypresses so that
    // the key sequence is delivered through Qt. That way clients can
    // intercept the shortcut and override its effect.
    [self handleKeyEvent:currentEvent eventType:int(QEvent::KeyPress)];
}

- (void)flagsChanged:(NSEvent *)nsevent
{
    ulong timestamp = [nsevent timestamp] * 1000;
    ulong modifiers = [nsevent modifierFlags];
    Qt::KeyboardModifiers qmodifiers = [QNSView convertKeyModifiers:modifiers];

    // calculate the delta and remember the current modifiers for next time
    static ulong m_lastKnownModifiers;
    ulong lastKnownModifiers = m_lastKnownModifiers;
    ulong delta = lastKnownModifiers ^ modifiers;
    m_lastKnownModifiers = modifiers;

    struct qt_mac_enum_mapper
    {
        ulong mac_mask;
        Qt::Key qt_code;
    };
    static qt_mac_enum_mapper modifier_key_symbols[] = {
        { NSShiftKeyMask, Qt::Key_Shift },
        { NSControlKeyMask, Qt::Key_Meta },
        { NSCommandKeyMask, Qt::Key_Control },
        { NSAlternateKeyMask, Qt::Key_Alt },
        { NSAlphaShiftKeyMask, Qt::Key_CapsLock },
        { 0ul, Qt::Key_unknown } };
    for (int i = 0; modifier_key_symbols[i].mac_mask != 0u; ++i) {
        uint mac_mask = modifier_key_symbols[i].mac_mask;
        if ((delta & mac_mask) == 0u)
            continue;

        QWindowSystemInterface::handleKeyEvent(m_window,
                                               timestamp,
                                               (lastKnownModifiers & mac_mask) ? QEvent::KeyRelease : QEvent::KeyPress,
                                               modifier_key_symbols[i].qt_code,
                                               qmodifiers ^ [QNSView convertKeyModifiers:mac_mask]);
    }
}

- (void) insertNewline:(id)sender
{
    Q_UNUSED(sender);
    m_resendKeyEvent = true;
}

- (void) doCommandBySelector:(SEL)aSelector
{
    [self tryToPerform:aSelector with:self];
}

- (void) insertText:(id)aString replacementRange:(NSRange)replacementRange
{
    Q_UNUSED(replacementRange)

    if (m_sendKeyEvent && m_composingText.isEmpty() && [aString isEqualToString:m_inputSource]) {
        // don't send input method events for simple text input (let handleKeyEvent send key events instead)
        return;
    }

    QString commitString;
    if ([aString length]) {
        if ([aString isKindOfClass:[NSAttributedString class]]) {
            commitString = QCFString::toQString(reinterpret_cast<CFStringRef>([aString string]));
        } else {
            commitString = QCFString::toQString(reinterpret_cast<CFStringRef>(aString));
        };
    }
    QObject *fo = QGuiApplication::focusObject();
    if (fo) {
        QInputMethodQueryEvent queryEvent(Qt::ImEnabled);
        if (QCoreApplication::sendEvent(fo, &queryEvent)) {
            if (queryEvent.value(Qt::ImEnabled).toBool()) {
                QInputMethodEvent e;
                e.setCommitString(commitString);
                QCoreApplication::sendEvent(fo, &e);
                // prevent handleKeyEvent from sending a key event
                m_sendKeyEvent = false;
            }
        }
    }

    m_composingText.clear();
}

- (void) setMarkedText:(id)aString selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange
{
    Q_UNUSED(replacementRange)
    QString preeditString;

    QList<QInputMethodEvent::Attribute> attrs;
    attrs<<QInputMethodEvent::Attribute(QInputMethodEvent::Cursor, selectedRange.location + selectedRange.length, 1, QVariant());

    if ([aString isKindOfClass:[NSAttributedString class]]) {
        // Preedit string has attribution
        preeditString = QCFString::toQString(reinterpret_cast<CFStringRef>([aString string]));
        int composingLength = preeditString.length();
        int index = 0;
        // Create attributes for individual sections of preedit text
        while (index < composingLength) {
            NSRange effectiveRange;
            NSRange range = NSMakeRange(index, composingLength-index);
            NSDictionary *attributes = [aString attributesAtIndex:index
                                            longestEffectiveRange:&effectiveRange
                                                          inRange:range];
            NSNumber *underlineStyle = [attributes objectForKey:NSUnderlineStyleAttributeName];
            if (underlineStyle) {
                QColor clr (Qt::black);
                NSColor *color = [attributes objectForKey:NSUnderlineColorAttributeName];
                if (color) {
                    clr = qt_mac_toQColor(color);
                }
                QTextCharFormat format;
                format.setFontUnderline(true);
                format.setUnderlineColor(clr);
                attrs<<QInputMethodEvent::Attribute(QInputMethodEvent::TextFormat,
                                                    effectiveRange.location,
                                                    effectiveRange.length,
                                                    format);
            }
            index = effectiveRange.location + effectiveRange.length;
        }
    } else {
        // No attributes specified, take only the preedit text.
        preeditString = QCFString::toQString(reinterpret_cast<CFStringRef>(aString));
    }

    if (attrs.isEmpty()) {
        QTextCharFormat format;
        format.setFontUnderline(true);
        attrs<<QInputMethodEvent::Attribute(QInputMethodEvent::TextFormat,
                                            0, preeditString.length(), format);
    }

    m_composingText = preeditString;

    QObject *fo = QGuiApplication::focusObject();
    if (fo) {
        QInputMethodQueryEvent queryEvent(Qt::ImEnabled);
        if (QCoreApplication::sendEvent(fo, &queryEvent)) {
            if (queryEvent.value(Qt::ImEnabled).toBool()) {
                QInputMethodEvent e(preeditString, attrs);
                QCoreApplication::sendEvent(fo, &e);
                // prevent handleKeyEvent from sending a key event
                m_sendKeyEvent = false;
            }
        }
    }
}

- (void) unmarkText
{
    if (!m_composingText.isEmpty()) {
        QObject *fo = QGuiApplication::focusObject();
        if (fo) {
            QInputMethodQueryEvent queryEvent(Qt::ImEnabled);
            if (QCoreApplication::sendEvent(fo, &queryEvent)) {
                if (queryEvent.value(Qt::ImEnabled).toBool()) {
                    QInputMethodEvent e;
                    e.setCommitString(m_composingText);
                    QCoreApplication::sendEvent(fo, &e);
                }
            }
        }
    }
    m_composingText.clear();
}

- (BOOL) hasMarkedText
{
    return (m_composingText.isEmpty() ? NO: YES);
}

- (NSAttributedString *) attributedSubstringForProposedRange:(NSRange)aRange actualRange:(NSRangePointer)actualRange
{
    Q_UNUSED(actualRange)
    QObject *fo = QGuiApplication::focusObject();
    if (!fo)
        return nil;
    QInputMethodQueryEvent queryEvent(Qt::ImEnabled | Qt::ImCurrentSelection);
    if (!QCoreApplication::sendEvent(fo, &queryEvent))
        return nil;
    if (!queryEvent.value(Qt::ImEnabled).toBool())
        return nil;

    QString selectedText = queryEvent.value(Qt::ImCurrentSelection).toString();
    if (selectedText.isEmpty())
        return nil;

    QCFString string(selectedText.mid(aRange.location, aRange.length));
    const NSString *tmpString = reinterpret_cast<const NSString *>((CFStringRef)string);
    return [[[NSAttributedString alloc]  initWithString:const_cast<NSString *>(tmpString)] autorelease];
}

- (NSRange) markedRange
{
    NSRange range;
    if (!m_composingText.isEmpty()) {
        range.location = 0;
        range.length = m_composingText.length();
    } else {
        range.location = NSNotFound;
        range.length = 0;
    }
    return range;
}

- (NSRange) selectedRange
{
    NSRange selectedRange = {NSNotFound, 0};
    selectedRange.location = NSNotFound;
    selectedRange.length = 0;

    QObject *fo = QGuiApplication::focusObject();
    if (!fo)
        return selectedRange;
    QInputMethodQueryEvent queryEvent(Qt::ImEnabled | Qt::ImCurrentSelection);
    if (!QCoreApplication::sendEvent(fo, &queryEvent))
        return selectedRange;
    if (!queryEvent.value(Qt::ImEnabled).toBool())
        return selectedRange;

    QString selectedText = queryEvent.value(Qt::ImCurrentSelection).toString();

    if (!selectedText.isEmpty()) {
        selectedRange.location = 0;
        selectedRange.length = selectedText.length();
    }
    return selectedRange;
}

- (NSRect) firstRectForCharacterRange:(NSRange)aRange actualRange:(NSRangePointer)actualRange
{
    Q_UNUSED(aRange)
    Q_UNUSED(actualRange)
    QObject *fo = QGuiApplication::focusObject();
    if (!fo)
        return NSZeroRect;

    QInputMethodQueryEvent queryEvent(Qt::ImEnabled);
    if (!QCoreApplication::sendEvent(fo, &queryEvent))
        return NSZeroRect;
    if (!queryEvent.value(Qt::ImEnabled).toBool())
        return NSZeroRect;

    if (!m_window)
        return NSZeroRect;

    // The returned rect is always based on the internal cursor.
    QRect mr = qApp->inputMethod()->cursorRectangle().toRect();
    QPoint mp = m_window->mapToGlobal(mr.bottomLeft());

    NSRect rect;
    rect.origin.x = mp.x();
    rect.origin.y = qt_mac_flipYCoordinate(mp.y());
    rect.size.width = mr.width();
    rect.size.height = mr.height();
    return rect;
}

- (NSUInteger)characterIndexForPoint:(NSPoint)aPoint
{
    // We don't support cursor movements using mouse while composing.
    Q_UNUSED(aPoint);
    return NSNotFound;
}

- (NSArray*) validAttributesForMarkedText
{
    if (m_window != QGuiApplication::focusWindow())
        return nil;

    QObject *fo = QGuiApplication::focusObject();
    if (!fo)
        return nil;

    QInputMethodQueryEvent queryEvent(Qt::ImEnabled);
    if (!QCoreApplication::sendEvent(fo, &queryEvent))
        return nil;
    if (!queryEvent.value(Qt::ImEnabled).toBool())
        return nil;

    // Support only underline color/style.
    return [NSArray arrayWithObjects:NSUnderlineColorAttributeName,
                                     NSUnderlineStyleAttributeName, nil];
}

-(void)registerDragTypes
{
    QMacAutoReleasePool pool;
    QStringList customTypes = qt_mac_enabledDraggedTypes();
    if (currentCustomDragTypes == 0 || *currentCustomDragTypes != customTypes) {
        if (currentCustomDragTypes == 0)
            currentCustomDragTypes = new QStringList();
        *currentCustomDragTypes = customTypes;
        const NSString* mimeTypeGeneric = @"com.trolltech.qt.MimeTypeName";
        NSMutableArray *supportedTypes = [NSMutableArray arrayWithObjects:NSColorPboardType,
                       NSFilenamesPboardType, NSStringPboardType,
                       NSFilenamesPboardType, NSPostScriptPboardType, NSTIFFPboardType,
                       NSRTFPboardType, NSTabularTextPboardType, NSFontPboardType,
                       NSRulerPboardType, NSFileContentsPboardType, NSColorPboardType,
                       NSRTFDPboardType, NSHTMLPboardType,
                       NSURLPboardType, NSPDFPboardType, NSVCardPboardType,
                       NSFilesPromisePboardType, NSInkTextPboardType,
                       NSMultipleTextSelectionPboardType, mimeTypeGeneric, nil];
        // Add custom types supported by the application.
        for (int i = 0; i < customTypes.size(); i++) {
           [supportedTypes addObject:QCFString::toNSString(customTypes[i])];
        }
        [self registerForDraggedTypes:supportedTypes];
    }
}

static QWindow *findEventTargetWindow(QWindow *candidate)
{
    while (candidate) {
        if (!(candidate->flags() & Qt::WindowTransparentForInput))
            return candidate;
        candidate = candidate->parent();
    }
    return candidate;
}

static QPoint mapWindowCoordinates(QWindow *source, QWindow *target, QPoint point)
{
    return target->mapFromGlobal(source->mapToGlobal(point));
}

- (NSDragOperation) draggingSourceOperationMaskForLocal:(BOOL)isLocal
{
    Q_UNUSED(isLocal);
    QCocoaDrag* nativeDrag = QCocoaIntegration::instance()->drag();
    return qt_mac_mapDropActions(nativeDrag->currentDrag()->supportedActions());
}

- (BOOL) ignoreModifierKeysWhileDragging
{
    return NO;
}

- (BOOL)wantsPeriodicDraggingUpdates
{
    // From the documentation:
    //
    // "If the destination returns NO, these messages are sent only when the mouse moves
    //  or a modifier flag changes. Otherwise the destination gets the default behavior,
    //  where it receives periodic dragging-updated messages even if nothing changes."
    //
    // We do not want these constant drag update events while mouse is stationary,
    // since we do all animations (autoscroll) with timers.
    return NO;
}


- (BOOL)wantsPeriodicDraggingUpdates:(void *)dummy
{
    // This method never gets called. It's a workaround for Apple's
    // bug: they first respondsToSelector : @selector(wantsPeriodicDraggingUpdates:)
    // (note ':') and then call -wantsPeriodicDraggingUpdate (without colon).
    // So, let's make them happy.
    Q_UNUSED(dummy);

    return NO;
}

- (void)updateCursorFromDragResponse:(QPlatformDragQtResponse)response drag:(QCocoaDrag *)drag
{
    const QPixmap pixmapCursor = drag->currentDrag()->dragCursor(response.acceptedAction());
    NSCursor *nativeCursor = nil;

    if (pixmapCursor.isNull()) {
        switch (response.acceptedAction()) {
            case Qt::CopyAction:
                nativeCursor = [NSCursor dragCopyCursor];
                break;
            case Qt::LinkAction:
                nativeCursor = [NSCursor dragLinkCursor];
                break;
            case Qt::IgnoreAction:
                // Uncomment the next lines if forbiden cursor wanted on non droppable targets.
                /*nativeCursor = [NSCursor operationNotAllowedCursor];
                break;*/
            case Qt::MoveAction:
            default:
                nativeCursor = [NSCursor arrowCursor];
                break;
        }
    }
    else {
        NSImage *nsimage = qt_mac_create_nsimage(pixmapCursor);
        nativeCursor = [[NSCursor alloc] initWithImage:nsimage hotSpot:NSZeroPoint];
        [nsimage release];
    }

    // change the cursor
    [nativeCursor set];

    // Make sure the cursor is updated correctly if the mouse does not move and window is under cursor
    // by creating a fake move event
    if (m_updatingDrag)
        return;

    const QPoint mousePos(QCursor::pos());
    CGEventRef moveEvent(CGEventCreateMouseEvent(
        NULL, kCGEventMouseMoved,
        CGPointMake(mousePos.x(), mousePos.y()),
        kCGMouseButtonLeft // ignored
    ));
    CGEventPost(kCGHIDEventTap, moveEvent);
    CFRelease(moveEvent);
}

- (NSDragOperation)draggingEntered:(id <NSDraggingInfo>)sender
{
    return [self handleDrag : sender];
}

- (NSDragOperation)draggingUpdated:(id <NSDraggingInfo>)sender
{
    m_updatingDrag = true;
    const NSDragOperation ret([self handleDrag : sender]);
    m_updatingDrag = false;

    return ret;
}

// Sends drag update to Qt, return the action
- (NSDragOperation)handleDrag:(id <NSDraggingInfo>)sender
{
    NSPoint windowPoint = [self convertPoint: [sender draggingLocation] fromView: nil];
    QPoint qt_windowPoint(windowPoint.x, windowPoint.y);
    Qt::DropActions qtAllowed = qt_mac_mapNSDragOperations([sender draggingSourceOperationMask]);

    QWindow *target = findEventTargetWindow(m_window);
    if (!target)
        return NSDragOperationNone;

    // update these so selecting move/copy/link works
    QGuiApplicationPrivate::modifier_buttons = [QNSView convertKeyModifiers: [[NSApp currentEvent] modifierFlags]];

    QPlatformDragQtResponse response(false, Qt::IgnoreAction, QRect());
    QCocoaDrag* nativeDrag = QCocoaIntegration::instance()->drag();
    if (nativeDrag->currentDrag()) {
        // The drag was started from within the application
        response = QWindowSystemInterface::handleDrag(target, nativeDrag->platformDropData(), mapWindowCoordinates(m_window, target, qt_windowPoint), qtAllowed);
        [self updateCursorFromDragResponse:response drag:nativeDrag];
    } else {
        QCocoaDropData mimeData([sender draggingPasteboard]);
        response = QWindowSystemInterface::handleDrag(target, &mimeData, mapWindowCoordinates(m_window, target, qt_windowPoint), qtAllowed);
    }

    return qt_mac_mapDropAction(response.acceptedAction());
}

- (void)draggingExited:(id <NSDraggingInfo>)sender
{
    QWindow *target = findEventTargetWindow(m_window);
    if (!target)
        return;

    NSPoint windowPoint = [self convertPoint: [sender draggingLocation] fromView: nil];
    QPoint qt_windowPoint(windowPoint.x, windowPoint.y);

    // Send 0 mime data to indicate drag exit
    QWindowSystemInterface::handleDrag(target, 0, mapWindowCoordinates(m_window, target, qt_windowPoint), Qt::IgnoreAction);
}

// called on drop, send the drop to Qt and return if it was accepted.
- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender
{
    QWindow *target = findEventTargetWindow(m_window);
    if (!target)
        return false;

    NSPoint windowPoint = [self convertPoint: [sender draggingLocation] fromView: nil];
    QPoint qt_windowPoint(windowPoint.x, windowPoint.y);
    Qt::DropActions qtAllowed = qt_mac_mapNSDragOperations([sender draggingSourceOperationMask]);

    QPlatformDropQtResponse response(false, Qt::IgnoreAction);
    QCocoaDrag* nativeDrag = QCocoaIntegration::instance()->drag();
    if (nativeDrag->currentDrag()) {
        // The drag was started from within the application
        response = QWindowSystemInterface::handleDrop(target, nativeDrag->platformDropData(), mapWindowCoordinates(m_window, target, qt_windowPoint), qtAllowed);
    } else {
        QCocoaDropData mimeData([sender draggingPasteboard]);
        response = QWindowSystemInterface::handleDrop(target, &mimeData, mapWindowCoordinates(m_window, target, qt_windowPoint), qtAllowed);
    }
    if (response.isAccepted()) {
        QCocoaDrag* nativeDrag = QCocoaIntegration::instance()->drag();
        nativeDrag->setAcceptedAction(response.acceptedAction());
    }
    return response.isAccepted();
}

- (void)draggedImage:(NSImage*) img endedAt:(NSPoint) point operation:(NSDragOperation) operation
{
    Q_UNUSED(img);
    Q_UNUSED(operation);
    QWindow *target = findEventTargetWindow(m_window);
    if (!target)
        return;

// keep our state, and QGuiApplication state (buttons member) in-sync,
// or future mouse events will be processed incorrectly
    m_buttons &= ~(m_sendUpAsRightButton ? Qt::RightButton : Qt::LeftButton);

    NSPoint windowPoint = [self convertPoint: point fromView: nil];
    QPoint qtWindowPoint(windowPoint.x, windowPoint.y);

    NSWindow *window = [self window];
    NSPoint screenPoint = [window convertRectToScreen:NSMakeRect(point.x, point.y, 0, 0)].origin;
    QPoint qtScreenPoint = QPoint(screenPoint.x, qt_mac_flipYCoordinate(screenPoint.y));

    QWindowSystemInterface::handleMouseEvent(target, mapWindowCoordinates(m_window, target, qtWindowPoint), qtScreenPoint, m_buttons);
}

// Returns the int value for an environment variable, or the default value if no good.
static int qEnvironmentVariableIntValue(const char *name, int def)
{
    bool ok = false;
    int val = qEnvironmentVariableIntValue(name, &ok);
    return ok ? val : def;
}

- (void)requestUpdate
{
    m_requestUpdatePending = true;

    if (m_displayLinkEnable) {
        QMutexLocker lock(&m_displayLinkMutex);
        m_displayLinkDirty = QRegion(QRect(QPoint(0, 0), m_platformWindow->geometry().size()));
        [self requestCVDisplayLinkUpdate];
    } else {
        static int timeout = qEnvironmentVariableIntValue("QT_QPA_UPDATE_IDLE_TIME", 5);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, timeout * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            [self setNeedsDisplay:YES];
        });
    }
}

- (void)requestUpdateWithRegion:(QRegion) region
{
    m_requestUpdatePending = true;

    if (m_displayLinkEnable) {
        QMutexLocker lock(&m_displayLinkMutex);
        m_displayLinkDirty = region;
        [self requestCVDisplayLinkUpdate];
    } else {
        static int timeout = qEnvironmentVariableIntValue("QT_QPA_UPDATE_IDLE_TIME", 5);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, timeout * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            foreach (QRect rect, region.rects())
                [self setNeedsDisplayInRect:qt_mac_toNSRect(rect)];
        });
    }
}

- (void)initializeDisplayLinkMembers
{
    m_displayLinkEnable = false;
    m_displayLink = 0;
    m_displayLinkSerial = 0;
    m_displayLinkSerialAtTimerSchedule = 0;
    m_displayLinkStopping = false;
    m_isDisplayLinkUpdate = false;
}

- (void)createDisplayLink
{
    CVDisplayLinkCreateWithActiveCGDisplays(&m_displayLink);
    CVDisplayLinkSetOutputCallback(m_displayLink, &qNsViewDisplayLinkCallback, self);
}

- (void)destroyDisplayLink
{
    qCDebug(lcQpaCocoaWindow) << "[QNSView destroyDisplayLink]" << m_window;

    // Do nothing if already destroyed.
    if (!m_displayLink)
        return;

    [self stopDisplayLink];

    CVDisplayLinkRelease(m_displayLink);
    m_displayLink = 0;
    [m_displayLinkStopTimer invalidate];
    // [m_displayLinkStopTimer release]; ??
    m_displayLinkStopTimer = 0;
}

- (void)startDisplayLink
{
    qCDebug(lcQpaCocoaWindow) << "[QNSView startDisplayLink]" << m_window;

    // Start the display link if needed
    if (!CVDisplayLinkIsRunning(m_displayLink)) {
        m_displayLinkStopping = false;
        CVDisplayLinkStart(m_displayLink);
    }
}

- (void)stopDisplayLink
{
    qCDebug(lcQpaCocoaWindow) << "[QNSView stopDisplayLink]" << m_window;

    // Calling CVDisplayLinkStop() while the display link thread is in
    // the callback will block until the callback returns. Wake it to
    // prevent deadlocking if the display link thread is waiting for
    // the GUI thread. Set displayLinkDisable to make sure this wakeup
    // does not trigger a repaint.
    {
        QMutexLocker lock(&m_displayLinkMutex);
        m_displayLinkStopping = true;
        m_displayLinkWait.wakeAll();
    }
    CVDisplayLinkStop(m_displayLink);
}

- (void)requestCVDisplayLinkUpdate
{
    qCDebug(lcQpaCocoaWindow) << "[QNSView requestCVDisplayLinkUpdate]" << m_window;

    [self startDisplayLink];
    ++m_displayLinkSerial;

    // Schedule the stop timer if not already scheduled. This timer will stop
    // the displaylink if/when there are no more requestUpdate calls.
    if (!m_displayLinkStopTimer || ![m_displayLinkStopTimer isValid])
        [self scheduleStopDisplayLinkTimer];
}

- (void)scheduleStopDisplayLinkTimer
{
    m_displayLinkSerialAtTimerSchedule = m_displayLinkSerial;

    // Select a delay which determines how often Qt will check
    // if the animatons have stopped. The tradeoff is timer activity
    // while animating vs. displaylink activity while not animating.
    NSTimeInterval delay = 10.0/60.0;

    m_displayLinkStopTimer =
        [NSTimer scheduledTimerWithTimeInterval:delay
                                         target:self
                                       selector:@selector(stopDisplayLinkTimerFire)
                                      userInfo:nil
                                       repeats:NO];
}

- (void)stopDisplayLinkTimerFire
{
    [m_displayLinkStopTimer invalidate];
    m_displayLinkStopTimer = 0;

    if (!CVDisplayLinkIsRunning(m_displayLink))
        return;

    // The dislplay link can be stopped if there was no requestUpdate
    // calls since the timer was scheduled. The application is no longer
    // requesting updates.
    if (m_displayLinkSerial == m_displayLinkSerialAtTimerSchedule) {
        [self stopDisplayLink];
    } else {
        // Othervise we assume the displaylink should keep running
        // and schedule the timer to check again.
        [self scheduleStopDisplayLinkTimer];
    }
}

CVReturn qNsViewDisplayLinkCallback(CVDisplayLinkRef displayLink, const CVTimeStamp* now, const CVTimeStamp* outputTime,
                                    CVOptionFlags flagsIn, CVOptionFlags* flagsOut, void* displayLinkContext)
{
    Q_UNUSED(displayLink);
    Q_UNUSED(now);
    Q_UNUSED(outputTime);
    Q_UNUSED(flagsIn);
    Q_UNUSED(flagsOut);

    // Debug
#if 0
    qDebug() << "qNsViewDisplayLinkCallback now" << now->hostTime / CVGetHostClockFrequency();
    qDebug() << "qNsViewDisplayLinkCallback output Time" << outputTime->hostTime / CVGetHostClockFrequency();
    uint64_t delta = outputTime->hostTime - now->hostTime;
    qDebug() << "delta" << delta / CVGetHostClockFrequency();
#endif

    [(QNSView*) displayLinkContext triggerUpdateRequest:now output:outputTime];
    return kCVReturnSuccess;
}

- (void)triggerUpdateRequest:(const CVTimeStamp *) now output:(const CVTimeStamp *)output
{
    QMutexLocker lock(&m_displayLinkMutex);

    qCDebug(lcQpaCocoaWindow) << "[QNSView triggerUpdateRequest]" << m_window << "disabled" << m_displayLinkStopping;

    if (m_displayLinkStopping)
        return;

    // Mark the next GUI thread update as an display link update.
    m_isDisplayLinkUpdate = true;

    // Store timing value pointers for the GUI thread.
    m_displayLinkNowTime = now;
    m_displayLinkOutputTime = output;

    // Trigger native view/layer update, which will call sendUpdateRequest below
    // on the GUI thread.
    if (m_platformWindow->m_inCustomLayerMode) {
        // Layer setNeedsDisplay seems to repaint immediately using the the
        // calling thread. Schedule call on GUI thread.
        dispatch_async(dispatch_get_main_queue(), ^{

            // The QCocoaWindow may have been deleted by the time we
            // get here (this block keeps the QNSView alive). If so the
            // display link disable flag has been set an we return early.
            if (m_displayLinkStopping)
                return;

            [[self layer] setNeedsDisplay];
            [[self layer] displayIfNeeded];
        });
    } else {
        // Call setNeedsDisplay which repaints later on the GUI thread.
        foreach (QRect rect, m_displayLinkDirty.rects())
            [self setNeedsDisplayInRect:qt_mac_toNSRect(rect)];
    }

    // Wait until the GUI thread has finished processing the update.
    // This provides rate limiting in case the GUI thread falls behind
    // and also keeps the CVTimeStamp pointers valid for the duration
    // of the update event.
    m_displayLinkWait.wait(&m_displayLinkMutex);

    m_displayLinkNowTime = 0;
    m_displayLinkOutputTime = 0;
}

// This function is called either from the displaylink calback or in response
// to window visibility or geometry changes, in both cases via drawRect. It
// requests a synchronous repaint from Qt, either via expose or updateRequest events.
- (void)sendUpdateRequest
{
    qCDebug(lcQpaCocoaWindow) << "[QNSView sendUpdateRequest]" << m_window;

    // Check if this is a displaylink update. If m_isDisplayLinkUpdate is set then
    // the display link thread is waiting on m_displayLinkWait.
    m_displayLinkMutex.lock();
    const bool isDisplayLinkUpdate = m_isDisplayLinkUpdate;
    if (isDisplayLinkUpdate)
        m_isDisplayLinkUpdate = false;
    m_displayLinkMutex.unlock();

    // There may be spurious wakeups for the purpose of stopping the display link.
    if (isDisplayLinkUpdate && m_displayLinkStopping) {
        qDebug() << "Display link update request dropped: display link was disabled";
        // Note: m_displayLinkWait.wakeAll() has already been called in this case
        return;
    }

    // If reuqestUdpate() has been called then the update has to be deliverd
    // via deliverUpdateRequest in order to keep QWindowPrivate::updateRequestPending
    // in sync.
    if (m_requestUpdatePending) {
        m_requestUpdatePending = false;
        m_platformWindow->deliverUpdateRequest();
    } else {
        // If geometry has changed the repaint has to be deliverd happen via an expose event.
        QSize viewSize = qt_mac_toQSize(self.frame.size);
        qreal dpr = m_platformWindow->devicePixelRatio();
        m_platformWindow->updateExposedState(viewSize, dpr);
    }

    // Wake the displaylink thread, allowing it to return from the displaylink callback.
    if (isDisplayLinkUpdate)
        m_displayLinkWait.wakeAll();
}

@end
