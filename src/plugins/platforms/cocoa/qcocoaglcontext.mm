/****************************************************************************
**
** Copyright (C) 2015 The Qt Company Ltd.
** Contact: http://www.qt.io/licensing/
**
** This file is part of the plugins of the Qt Toolkit.
**
** $QT_BEGIN_LICENSE:LGPL21$
** Commercial License Usage
** Licensees holding valid commercial Qt licenses may use this file in
** accordance with the commercial license agreement provided with the
** Software or, alternatively, in accordance with the terms contained in
** a written agreement between you and The Qt Company. For licensing terms
** and conditions see http://www.qt.io/terms-conditions. For further
** information use the contact form at http://www.qt.io/contact-us.
**
** GNU Lesser General Public License Usage
** Alternatively, this file may be used under the terms of the GNU Lesser
** General Public License version 2.1 or version 3 as published by the Free
** Software Foundation and appearing in the file LICENSE.LGPLv21 and
** LICENSE.LGPLv3 included in the packaging of this file. Please review the
** following information to ensure the GNU Lesser General Public License
** requirements will be met: https://www.gnu.org/licenses/lgpl.html and
** http://www.gnu.org/licenses/old-licenses/lgpl-2.1.html.
**
** As a special exception, The Qt Company gives you certain additional
** rights. These rights are described in The Qt Company LGPL Exception
** version 1.1, included in the file LGPL_EXCEPTION.txt in this package.
**
** $QT_END_LICENSE$
**
****************************************************************************/

#include "qcocoaglcontext.h"
#include "qcocoawindow.h"
#include "qcocoahelpers.h"
#include "qcocoagllayer.h"

#include <qdebug.h>
#include <QtCore/private/qcore_mac_p.h>
#include <QtPlatformSupport/private/cglconvenience_p.h>
#include <QtPlatformHeaders/qcocoanativecontext.h>

#import <AppKit/AppKit.h>

QT_BEGIN_NAMESPACE

static inline QByteArray getGlString(GLenum param)
{
    if (const GLubyte *s = glGetString(param))
        return QByteArray(reinterpret_cast<const char*>(s));
    return QByteArray();
}

#if !defined(GL_CONTEXT_FLAGS)
#define GL_CONTEXT_FLAGS 0x821E
#endif

#if !defined(GL_CONTEXT_FLAG_FORWARD_COMPATIBLE_BIT)
#define GL_CONTEXT_FLAG_FORWARD_COMPATIBLE_BIT 0x0001
#endif

#if !defined(GL_CONTEXT_PROFILE_MASK)
#define GL_CONTEXT_PROFILE_MASK 0x9126
#endif

#if !defined(GL_CONTEXT_CORE_PROFILE_BIT)
#define GL_CONTEXT_CORE_PROFILE_BIT 0x00000001
#endif

#if !defined(GL_CONTEXT_COMPATIBILITY_PROFILE_BIT)
#define GL_CONTEXT_COMPATIBILITY_PROFILE_BIT 0x00000002
#endif

static void updateFormatFromContext(QSurfaceFormat *format)
{
    Q_ASSERT(format);

    // Update the version, profile, and context bit of the format
    int major = 0, minor = 0;
    QByteArray versionString(getGlString(GL_VERSION));
    if (QPlatformOpenGLContext::parseOpenGLVersion(versionString, major, minor)) {
        format->setMajorVersion(major);
        format->setMinorVersion(minor);
    }

    format->setProfile(QSurfaceFormat::NoProfile);

    Q_ASSERT(format->renderableType() == QSurfaceFormat::OpenGL);
    if (format->version() < qMakePair(3, 0)) {
        format->setOption(QSurfaceFormat::DeprecatedFunctions);
        return;
    }

    // Version 3.0 onwards - check if it includes deprecated functionality
    GLint value = 0;
    glGetIntegerv(GL_CONTEXT_FLAGS, &value);
    if (!(value & GL_CONTEXT_FLAG_FORWARD_COMPATIBLE_BIT))
        format->setOption(QSurfaceFormat::DeprecatedFunctions);

    // Debug context option not supported on OS X
    if (format->version() < qMakePair(3, 2))
        return;

    // Version 3.2 and newer have a profile
    value = 0;
    glGetIntegerv(GL_CONTEXT_PROFILE_MASK, &value);

    if (value & GL_CONTEXT_CORE_PROFILE_BIT)
        format->setProfile(QSurfaceFormat::CoreProfile);
    else if (value & GL_CONTEXT_COMPATIBILITY_PROFILE_BIT)
        format->setProfile(QSurfaceFormat::CompatibilityProfile);
}

static void updateFormatFromPixelFormat(QSurfaceFormat *format, QSurfaceFormat requestedFormat, NSOpenGLPixelFormat *pixelFormat)
{
    int colorSize = -1;
    [pixelFormat getValues:&colorSize forAttribute:NSOpenGLPFAColorSize forVirtualScreen:0];
    if (colorSize > 0) {
        // This seems to return the total color buffer depth, including alpha
        format->setRedBufferSize(colorSize / 4);
        format->setGreenBufferSize(colorSize / 4);
        format->setBlueBufferSize(colorSize / 4);
    }

    // The pixel format always seems to return 8 for alpha. However, the framebuffer only
    // seems to have alpha enabled if we requested it explicitly. I can't find any other
    // attribute to check explicitly for this so we use our best guess for alpha.
    int alphaSize = -1;
    [pixelFormat getValues:&alphaSize forAttribute:NSOpenGLPFAAlphaSize forVirtualScreen:0];
    if (alphaSize > 0 && requestedFormat.alphaBufferSize() > 0)
        format->setAlphaBufferSize(alphaSize);

    int depthSize = -1;
    [pixelFormat getValues:&depthSize forAttribute:NSOpenGLPFADepthSize forVirtualScreen:0];
    if (depthSize > 0)
        format->setDepthBufferSize(depthSize);

    int stencilSize = -1;
    [pixelFormat getValues:&stencilSize forAttribute:NSOpenGLPFAStencilSize forVirtualScreen:0];
    if (stencilSize > 0)
        format->setStencilBufferSize(stencilSize);

    int samples = -1;
    [pixelFormat getValues:&samples forAttribute:NSOpenGLPFASamples forVirtualScreen:0];
    if (samples > 0)
        format->setSamples(samples);

    int doubleBuffered = -1;
    [pixelFormat getValues:&doubleBuffered forAttribute:NSOpenGLPFADoubleBuffer forVirtualScreen:0];
    format->setSwapBehavior(doubleBuffered == 1 ? QSurfaceFormat::DoubleBuffer : QSurfaceFormat::SingleBuffer);

    int steroBuffers = -1;
    [pixelFormat getValues:&steroBuffers forAttribute:NSOpenGLPFAStereo forVirtualScreen:0];
    if (steroBuffers == 1)
        format->setOption(QSurfaceFormat::StereoBuffers);
}

void (*QCocoaGLContext::getProcAddress(const QByteArray &procName))()
{
    return qcgl_getProcAddress(procName);
}

QSurfaceFormat QCocoaGLContext::format() const
{
    return m_format;
}

NSOpenGLPixelFormat *QCocoaGLContext::createPixelFormat(const QSurfaceFormat &format)
{
    return static_cast<NSOpenGLPixelFormat *>(qcgl_createNSOpenGLPixelFormat(format));
}

NSOpenGLContext *QCocoaGLContext::createGLContext(QSurfaceFormat format,
                                                  QPlatformOpenGLContext *share)
{
    NSOpenGLContext *context = nil;

    // we only support OpenGL contexts under Cocoa
    if (format.renderableType() == QSurfaceFormat::DefaultRenderableType)
        format.setRenderableType(QSurfaceFormat::OpenGL);
    if (format.renderableType() != QSurfaceFormat::OpenGL)
        return nil;

    // create native context for the requested pixel format and share
    NSOpenGLPixelFormat *pixelFormat =
        static_cast <NSOpenGLPixelFormat *>(qcgl_createNSOpenGLPixelFormat(format));
    NSOpenGLContext *shareContext = share ? static_cast<QCocoaGLContext *>(share)->nativeContext() : nil;
    context = createGLContext(pixelFormat, shareContext);

    const GLint interval = format.swapInterval() >= 0 ? format.swapInterval() : 1;
    [context setValues:&interval forParameter:NSOpenGLCPSwapInterval];

    if (format.alphaBufferSize() > 0) {
        int zeroOpacity = 0;
        [context setValues:&zeroOpacity forParameter:NSOpenGLCPSurfaceOpacity];
    }

    return context;
}

NSOpenGLContext *QCocoaGLContext::createGLContext(NSOpenGLPixelFormat *pixelFormat,
                                                  NSOpenGLContext *shareContext)
{
    NSOpenGLContext *context = [[NSOpenGLContext alloc] initWithFormat:pixelFormat shareContext:shareContext];

    // retry without sharing on context creation failure.
    if (!context && shareContext) {
        context = [[NSOpenGLContext alloc] initWithFormat:pixelFormat shareContext:nil];
        if (context)
            qWarning("QCocoaGLContext: Falling back to unshared context.");
    }

    // give up if we still did not get a native context
    [pixelFormat release];
    if (!context) {
        qWarning("QCocoaGLContext: Failed to create context.");
        return 0;
    }

    return context;
}

QSurfaceFormat QCocoaGLContext::updateSurfaceFormat(NSOpenGLContext *context, QSurfaceFormat requestedFormat)
{
    // At present it is impossible to turn an option off on a QSurfaceFormat (see
    // https://codereview.qt-project.org/#change,70599). So we have to populate
    // the actual surface format from scratch
    QSurfaceFormat format = QSurfaceFormat();
    format.setRenderableType(QSurfaceFormat::OpenGL);

    // CoreGL doesn't require a drawable to make the context current
    CGLContextObj oldContext = CGLGetCurrentContext();
    CGLContextObj ctx = static_cast<CGLContextObj>([context CGLContextObj]);
    CGLSetCurrentContext(ctx);

    // Get the data that OpenGL provides
    updateFormatFromContext(&format);

    // Get the data contained within the pixel format
    CGLPixelFormatObj cglPixelFormat = static_cast<CGLPixelFormatObj>(CGLGetPixelFormat(ctx));
    NSOpenGLPixelFormat *pixelFormat = [[NSOpenGLPixelFormat alloc] initWithCGLPixelFormatObj:cglPixelFormat];
    updateFormatFromPixelFormat(&format, requestedFormat, pixelFormat);
    [pixelFormat release];

    // Restore the original context
    CGLSetCurrentContext(oldContext);

    return format;
}

NSOpenGLContext *QCocoaGLContext::nativeContext() const
{
    return m_context;
}

QVariant QCocoaGLContext::nativeHandle() const
{
    return QVariant::fromValue<QCocoaNativeContext>(QCocoaNativeContext(m_context));
}

typedef QHash<QWindow *, QCocoaGLContext *> WindowContexts;
Q_GLOBAL_STATIC(WindowContexts, g_windowContexts);

QCocoaGLContext::QCocoaGLContext(QOpenGLContext *context, QWindow *targetWindow)
:m_isLayerContext(false)
,m_isValid(false)
//,m_format()
,m_context(nil)
,m_shareContext(nil)
,m_currentWindow(0)
,m_targetWindow(targetWindow)
{
    QVariant nativeHandle = context->nativeHandle();
    QCocoaGLContext *share = static_cast<QCocoaGLContext *>(context->shareHandle());

    // Inspect any given targetWindow to see if this is a layer-mode context, in which
    // case set the m_isLayerContext mode switch. If targetWindow is null, or has not
    // been created yet, this this can stil be determined later when a surface is provided
    // in makeCurrent().
    //
    // In layer mode most methods become no-ops, since CoreAnimation will make the
    // context current before calling the draw callback and also swap when drawing
    // is done. One important exception here is defaultFramebufferObject, which
    // returns the current FBO for the layer.Drawing outside of the callback is not
    // allowed in layer mode.
    if (targetWindow) {
        // Store window -> context acociation, for later lookup by layer initialization.
        g_windowContexts()->insert(targetWindow, this);

        // Layer mode checks. There are two, since this constructor may be called
        // before the platform window and native views have been created.
        if (targetWindow->handle()) {
            // There is a native QNSView which may be configured for layer mode.
            QCocoaWindow *cocoaWindow = static_cast<QCocoaWindow *>(targetWindow->handle());
            m_isLayerContext = cocoaWindow->m_inLayerMode;
        } else {
            // Layer mode has been requested for this QWindow, or globally.
            m_isLayerContext = qt_mac_resolveOption(NO, targetWindow,
                                                   "_q_mac_wantsLayer", "QT_MAC_WANTS_LAYER");
        }
    }

    qDebug() << "QCocoaGLContext target" << targetWindow  << "m_inLayerMode" << m_isLayerContext;

    // In layer mode, native context creation is lazy and we store the format
    // for later use in the layer context create callback.
    if (m_isLayerContext) {
//        m_format = context->format();
//        setActiveWindow(targetWindow);

//       if (nativeHandle.isValid())
//            qWarning("QCocoaGLContext: Specifying a native context in layer mode is not supported");

        // Assume we are good until native context creation possibly proves otherwise.
 //       m_isValid = true;
    }

    // Handle case where QOpenGLContect has been constructed with an existing
    // native NSOpenGLContext.
    if (nativeHandle.isValid()) {
        if (!nativeHandle.canConvert<QCocoaNativeContext>()) {
            qWarning("QCocoaGLContext: Requires a QCocoaNativeContext");
            return;
        }
        QCocoaNativeContext handle = nativeHandle.value<QCocoaNativeContext>();
        m_context = handle.context();
        if (!m_context) {
            qWarning("QCocoaGLContext: No NSOpenGLContext given");
            return;
        }
        [m_context retain];
        m_shareContext = share ? share->nativeContext() : nil;
    } else {
        qDebug() << "CreateGLContext";
        QMacAutoReleasePool pool; // For the SG Canvas render thread
        m_context = createGLContext(context->format(), share);
    }

    // NSView OpenGL surfaces can be ordered either above(default) or below the NSWindow.
    if (!m_isLayerContext) {
        const GLint order = qt_mac_resolveOption(1, "QT_MAC_OPENGL_SURFACE_ORDER");
        [m_context setValues:&order forParameter:NSOpenGLCPSurfaceOrder];
    }

    // Update the QSurfaceFormat object to match the actual configuration of the native context.
    m_format = updateSurfaceFormat(m_context, m_format);
}

QCocoaGLContext::~QCocoaGLContext()
{
    if (m_currentWindow && m_currentWindow.data()->handle())
        static_cast<QCocoaWindow *>(m_currentWindow.data()->handle())->setCurrentContext(0);

    [m_context release];
}

QCocoaGLContext *QCocoaGLContext::contextForTargetWindow(QWindow *window)
{
    return g_windowContexts()->value(window);
}

void QCocoaGLContext::swapBuffers(QPlatformSurface *surface)
{
    if (m_isLayerContext)
        return;

    QWindow *window = static_cast<QCocoaWindow *>(surface)->window();
    setActiveWindow(window);

    [m_context flushBuffer];
}

GLuint QCocoaGLContext::defaultFramebufferObject(QPlatformSurface *surface) const
{
    if (!m_isLayerContext)
        return QPlatformOpenGLContext::defaultFramebufferObject(surface);

    // Cast and dereference our way to the current FBO identifier on the layer
    QNSView *view = reinterpret_cast<QCocoaWindow* >(m_currentWindow->handle())->qtView();
    QCocoaOpenGLLayer *layer= (QCocoaOpenGLLayer *)[view layer];
    return layer->m_drawFbo;
}

bool QCocoaGLContext::makeCurrent(QPlatformSurface *surface)
{
    QMacAutoReleasePool pool;
    QCocoaWindow *cocoaWindow = static_cast<QCocoaWindow *>(surface);

    // A layer mode context is tied to a spesific window. Check that
    // makeCurrent is not trying to change it.
    if (m_isLayerContext)
        Q_ASSERT(m_currentWindow.data() == static_cast<QWindow *>(surface->surface()));

    // This point may be the first time the OpenGL context is connected
    // to a window. Check if that window is in layer mode and switch if so.
    if (cocoaWindow->m_inLayerMode)
        m_isLayerContext = true;

    setActiveWindow(cocoaWindow->window());

    // Normally, Core Animation will have made the context current
    if (!m_isLayerContext)
        [m_context makeCurrentContext];

    if (!m_isLayerContext)
        update();

    return true;
}

void QCocoaGLContext::doneCurrent()
{
    if (m_isLayerContext)
        return;

    if (m_currentWindow && m_currentWindow.data()->handle())
        static_cast<QCocoaWindow *>(m_currentWindow.data()->handle())->setCurrentContext(0);

    m_currentWindow.clear();

    [NSOpenGLContext clearCurrentContext];
}

bool QCocoaGLContext::isValid() const
{
    return m_isValid || m_context != nil;
}

bool QCocoaGLContext::isSharing() const
{
    return m_shareContext != nil;
}

void QCocoaGLContext::update()
{
    if (m_isLayerContext)
        return;

    [m_context update];
}

void QCocoaGLContext::windowWasHidden()
{
    if (m_isLayerContext)
        return;

    // If the window is hidden, we need to unset the m_currentWindow
    // variable so that succeeding makeCurrent's will not abort prematurely
    // because of the optimization in setActiveWindow.
    // Doing a full doneCurrent here is not preferable, because the GL context
    // might be rendering in a different thread at this time.
    m_currentWindow.clear();
}

void QCocoaGLContext::setActiveWindow(QWindow *window)
{
    if (window == m_currentWindow.data())
        return;

    if (m_currentWindow && m_currentWindow.data()->handle())
        static_cast<QCocoaWindow *>(m_currentWindow.data()->handle())->setCurrentContext(0);

    Q_ASSERT(window->handle());

    m_currentWindow = window;

    QCocoaWindow *cocoaWindow = static_cast<QCocoaWindow *>(window->handle());
    cocoaWindow->setCurrentContext(this);

    if (!m_isLayerContext)
        [(QNSView *) cocoaWindow->contentView() setQCocoaGLContext:this];
}

QT_END_NAMESPACE
