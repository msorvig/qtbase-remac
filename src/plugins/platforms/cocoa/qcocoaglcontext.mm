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

//
// QCocoaGLViewContext Implementation
//
QCocoaGLViewContext::QCocoaGLViewContext(const QSurfaceFormat &format, QPlatformOpenGLContext *share,
                                 const QVariant &nativeHandle, QWindow *targetWindow)
: m_shareContext(nil)
{
    m_targetWindow =targetWindow;

    if (!nativeHandle.isNull()) {
        if (!nativeHandle.canConvert<QCocoaNativeContext>()) {
            qWarning("QCocoaGLContext: Requires a QCocoaNativeContext");
            return;
        }
        QCocoaNativeContext handle = nativeHandle.value<QCocoaNativeContext>();
        NSOpenGLContext *context = handle.context();
        if (!context) {
            qWarning("QCocoaGLContext: No NSOpenGLContext given");
            return;
        }

        m_context = context;
        [m_context retain];
        m_shareContext = share ? static_cast<QCocoaGLContext *>(share)->nativeContext() : nil;
    } else {
        QMacAutoReleasePool pool; // For the SG Canvas render thread
        m_context = createGLContext(format, share);
    }

    // OpenGL surfaces can be ordered either above(default) or below the NSWindow.
    const GLint order = qt_mac_resolveOption(1, "QT_MAC_OPENGL_SURFACE_ORDER");
    [m_context setValues:&order forParameter:NSOpenGLCPSurfaceOrder];

    // Update the QSurfaceFormat object to match the actual configuration of the native context.
    m_format = updateSurfaceFormat(m_context, format);
}

QCocoaGLViewContext::~QCocoaGLViewContext()
{
    if (m_currentWindow && m_currentWindow.data()->handle())
        static_cast<QCocoaWindow *>(m_currentWindow.data()->handle())->setCurrentContext(0);

    [m_context release];
}

void QCocoaGLViewContext::swapBuffers(QPlatformSurface *surface)
{
    QWindow *window = static_cast<QCocoaWindow *>(surface)->window();
    setActiveWindow(window);

    [m_context flushBuffer];
}

bool QCocoaGLViewContext::makeCurrent(QPlatformSurface *surface)
{
    Q_ASSERT(surface->surface()->supportsOpenGL());
    QMacAutoReleasePool pool;

    QWindow *window = static_cast<QCocoaWindow *>(surface)->window();
    setActiveWindow(window);

    [m_context makeCurrentContext];
    update();
    return true;
}

void QCocoaGLViewContext::doneCurrent()
{
    if (m_currentWindow && m_currentWindow.data()->handle())
        static_cast<QCocoaWindow *>(m_currentWindow.data()->handle())->setCurrentContext(0);

    m_currentWindow.clear();

    [NSOpenGLContext clearCurrentContext];
}

bool QCocoaGLViewContext::isValid() const
{
    return m_context != nil;
}

bool QCocoaGLViewContext::isSharing() const
{
    return m_shareContext != nil;
}

void QCocoaGLViewContext::update()
{
    [m_context update];
}

void QCocoaGLViewContext::windowWasHidden()
{
    // If the window is hidden, we need to unset the m_currentWindow
    // variable so that succeeding makeCurrent's will not abort prematurely
    // because of the optimization in setActiveWindow.
    // Doing a full doneCurrent here is not preferable, because the GL context
    // might be rendering in a different thread at this time.
    m_currentWindow.clear();
}

void QCocoaGLViewContext::setActiveWindow(QWindow *window)
{
    if (window == m_currentWindow.data())
        return;

    if (m_currentWindow && m_currentWindow.data()->handle())
        static_cast<QCocoaWindow *>(m_currentWindow.data()->handle())->setCurrentContext(0);

    Q_ASSERT(window->handle());

    m_currentWindow = window;

    QCocoaWindow *cocoaWindow = static_cast<QCocoaWindow *>(window->handle());
    cocoaWindow->setCurrentContext(this);

    [(QNSView *) cocoaWindow->contentView() setQCocoaGLViewContext:this];
}

//
// QCocoaGLLayerContext is lazy and does not create the pixel format and
// native context right away. Instead, the format is stored and the
// the native context is crated in the context create callback from layer.
//
// In addition several of the functions are no-ops, including makeCurrent(),
// doneCurrent(), and swapBuffers(). This context only supports painting inside
// the layer callback, at which point the context is already current. In
// a similar fashion the layer will handle buffer swapping for us.
//
// This means that "free" usage of QOpenGLcontext is not supported when Qt
// is in layer mode. Instead we support something close to QOpenGLWidget:
// call update when you want to draw, and then actually draw in a paintEvent
// callback.
//
QCocoaGLLayerContext::QCocoaGLLayerContext(const QSurfaceFormat &format, QPlatformOpenGLContext *share,
                                           const QVariant &nativeHandle, QWindow *targetWindow)
{
    if (!nativeHandle.isNull()) {
        qWarning("QCocoaGLContext: Specifying a native context in layer mode is not supported");
        return;
    }

    m_format = format;
    m_context = 0;
    m_shareContext = share;
    m_targetWindow = targetWindow;

    // Assume we are good until native context creation possibly proves otherwise.
    m_isValid = true;
}

void QCocoaGLLayerContext::swapBuffers(QPlatformSurface *surface)
{
    Q_UNUSED(surface);
    // No-op: core canimation swaps buffers
}

bool QCocoaGLLayerContext::makeCurrent(QPlatformSurface *surface)
{
    Q_UNUSED(surface);
    // No-op: core canimation makes the context current before drawing
    return true;
}

void QCocoaGLLayerContext::doneCurrent()
{
    // No-op
}

bool QCocoaGLLayerContext::isSharing() const
{
    return m_shareContext != 0;
}

bool QCocoaGLLayerContext::isValid() const
{
    qDebug() << "is valid?";
    return m_isValid;
}

QT_END_NAMESPACE
