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

#include "qcocoaglcontext.h"
#include "qcocoawindow.h"
#include "qcocoahelpers.h"
#include "qcocoagllayer.h"

#include <qdebug.h>
#include <QtCore/private/qcore_mac_p.h>
#include <QtPlatformSupport/private/cglconvenience_p.h>
#include <QtPlatformHeaders/qcocoanativecontext.h>
#include <dlfcn.h>

#import <AppKit/AppKit.h>

QT_BEGIN_NAMESPACE

static QWindow *qwindow_cast(QSurface *surface)
{
    if (surface->surfaceClass() == QSurface::Window)
        return static_cast<QWindow *>(surface);
    return 0;
}

static QCocoaWindow *qcocoawindow_cast(QPlatformSurface *surface)
{
    if (surface->surface()->surfaceClass() == QSurface::Window)
        return static_cast<QCocoaWindow *>(surface);
    return 0;
}

static bool isCocoaWindowInOpenGLLayerMode(QPlatformSurface *surface)
{
    if (QCocoaWindow *cocoaWindow = qcocoawindow_cast(surface))
        return cocoaWindow->inOpenGLLayerMode();
    return false;
}

static bool isCocoaWindowInIOSurfaceMode(QPlatformSurface *surface)
{
    if (QCocoaWindow *cocoaWindow = qcocoawindow_cast(surface))
        return cocoaWindow->inIOSurfaceMode();
    return false;
}

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

QFunctionPointer QCocoaGLContext::getProcAddress(const char *procName)
{
    return (QFunctionPointer)dlsym(RTLD_DEFAULT, procName);
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

typedef QHash<void *, QCocoaGLContext *> WindowContexts;
Q_GLOBAL_STATIC(WindowContexts, g_windowContexts);

QCocoaGLContext::QCocoaGLContext(QOpenGLContext *context, QWindow *targetWindow)
:m_targetWindow(targetWindow)
,m_context(nil)
,m_shareContext(nil)
,m_iosurface(0)
,m_iosurfaceTexture(0)
,m_iosurfaceFrameBuffer(0)

{
    QVariant nativeHandle = context->nativeHandle();
    QCocoaGLContext *share = static_cast<QCocoaGLContext *>(context->shareHandle());

    // Store window -> context association, for later lookup by layer initialization.
    if (targetWindow)
        g_windowContexts()->insert(targetWindow, this);

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
        QMacAutoReleasePool pool; // For the SG Canvas render thread
        m_context = createGLContext(context->format(), share);
    }

    // NSView OpenGL surfaces can be ordered either above(default) or below the NSWindow.
    const GLint order = qt_mac_resolveOption(1, "QT_MAC_OPENGL_SURFACE_ORDER");
    [m_context setValues:&order forParameter:NSOpenGLCPSurfaceOrder];

    // Update the QSurfaceFormat object to match the actual configuration of the native context.
    m_format = updateSurfaceFormat(m_context, m_format);
}

QCocoaGLContext::~QCocoaGLContext()
{
    destroyIOSurfaceFBO();

    if (m_targetWindow != 0)
        g_windowContexts()->remove(m_targetWindow);

    if (QCocoaWindow *cocoaWindow = QCocoaWindow::get(m_currentWindow))
        cocoaWindow->setCurrentContext(0);

    [m_context release];
}

QCocoaGLContext *QCocoaGLContext::contextForTargetWindow(QWindow *window)
{
    return g_windowContexts()->value(window);
}

void QCocoaGLContext::swapBuffers(QPlatformSurface *surface)
{
    // No-op for layer mode: Core Animation will swap/flush for us.
    if (isCocoaWindowInOpenGLLayerMode(surface))
        return;

    [m_context flushBuffer];

    if (isCocoaWindowInIOSurfaceMode(surface))
        qcocoawindow_cast(surface)->setLayerContent(m_iosurface);
}

GLuint QCocoaGLContext::defaultFramebufferObject(QPlatformSurface *surface) const
{
    // Core Animation layers redirect to a non-default FBO; call
    // on QCocoaWindow to determine if this is the case.
    if (isCocoaWindowInOpenGLLayerMode(surface))
        return qcocoawindow_cast(surface)->defaultFramebufferObject();

    if (isCocoaWindowInIOSurfaceMode(surface))
        return m_iosurfaceFrameBuffer;

    return QPlatformOpenGLContext::defaultFramebufferObject(surface);
}

bool QCocoaGLContext::makeCurrent(QPlatformSurface *surface)
{
    QMacAutoReleasePool pool;

    // No-op for layer mode: Core Animation makes the context current.
    if (isCocoaWindowInOpenGLLayerMode(surface))
        return true;

    [m_context makeCurrentContext];

    if (isCocoaWindowInIOSurfaceMode(surface)) {
        // Resize IOSurface if needed.
        QWindow *window = qwindow_cast(surface->surface());
        QSize devicePixelSize = window->size() * window->devicePixelRatio();
        updateIOSurfaceIfNeeded(devicePixelSize);
    } else {
        // The setActiveWindow logic is run for "classic" OpenGL, where QCocoaWindow
        // needs to call back into the context on geometry changes etc.
        setActiveWindow(qcocoawindow_cast(surface)->window());
        [m_context update];
    }

    return true;
}

void QCocoaGLContext::doneCurrent()
{
    [NSOpenGLContext clearCurrentContext];

    // If m_currentWindow is set then setActiveWindow() has been run earlier and we clean up.
    if (m_currentWindow) {
        if (QCocoaWindow *cocoaWindow = QCocoaWindow::get(m_currentWindow))
            cocoaWindow->setCurrentContext(0);
        m_currentWindow.clear();
    }
}

bool QCocoaGLContext::isValid() const
{
    return m_context != nil;
}

bool QCocoaGLContext::isSharing() const
{
    return m_shareContext != nil;
}

void QCocoaGLContext::windowWasHidden()
{
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

    if (QCocoaWindow *cocoaWindow = QCocoaWindow::get(m_currentWindow))
        cocoaWindow->setCurrentContext(0);

    Q_ASSERT(window->handle());
    m_currentWindow = window;

    QCocoaWindow *cocoaWindow = QCocoaWindow::get(window);
    cocoaWindow->setCurrentContext(this);

    [(QNSView *) cocoaWindow->contentView() setQCocoaGLContext:this];
}

IOSurfaceRef QCocoaGLContext::createIOSurface(const QSize &size)
{
    unsigned pixelFormat = 'BGRA';
    unsigned bytesPerElement = 4;

    // Check system size limits
    int maxWidth = IOSurfaceGetPropertyMaximum(kIOSurfaceWidth);
    int maxHeight = IOSurfaceGetPropertyMaximum(kIOSurfaceHeight);
    if (size.width() > maxWidth || size.height() > maxHeight) {
        qWarning() << "QCocoaGLContext::createIOSurface: maximum IOSurface size exceeded"
                   << "size" << size << "max" << QSize(maxWidth, maxHeight);
        return nil;
    }

    size_t bytesPerRow = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, size.width() * bytesPerElement);
    size_t totalBytes = IOSurfaceAlignProperty(kIOSurfaceAllocSize, size.height() * bytesPerRow);
    NSDictionary *options = @{
        (id)kIOSurfaceWidth: @(size.width()),
        (id)kIOSurfaceHeight: @(size.height()),
        (id)kIOSurfacePixelFormat: @(pixelFormat),
        (id)kIOSurfaceBytesPerElement: @(bytesPerElement),
        (id)kIOSurfaceBytesPerRow: @(bytesPerRow),
        (id)kIOSurfaceAllocSize: @(totalBytes),
    };
    return IOSurfaceCreate(static_cast<CFDictionaryRef>(options));
}

void QCocoaGLContext::destroyIOSurfaceFBO()
{
    if (m_iosurfaceTexture) {
        glDeleteTextures(1, &m_iosurfaceTexture);
        m_iosurfaceTexture = 0;
    }
    if (m_iosurfaceFrameBuffer) {
        glDeleteFramebuffers(1, &m_iosurfaceFrameBuffer);
        m_iosurfaceFrameBuffer = 0;
    }
    if (m_iosurfaceDepthStencilBuffer) {
        glDeleteRenderbuffers(1, &m_iosurfaceDepthStencilBuffer);
        m_iosurfaceDepthStencilBuffer = 0;
    }
}

bool QCocoaGLContext::createIOSurfaceFBO(IOSurfaceRef ioSurfaceBuffer)
{
    // Reset
    destroyIOSurfaceFBO();

    // Cretate texture with IOSurface dimensions.
    CGLContextObj cgl_ctx = reinterpret_cast<CGLContextObj>([m_context CGLContextObj]);
    GLuint width = IOSurfaceGetWidth(ioSurfaceBuffer);
    GLuint height = IOSurfaceGetHeight(ioSurfaceBuffer);
    glGenTextures(1, &m_iosurfaceTexture);
    glBindTexture(GL_TEXTURE_RECTANGLE, m_iosurfaceTexture);
    CGLTexImageIOSurface2D(cgl_ctx, GL_TEXTURE_RECTANGLE, GL_RGBA, width, height, GL_BGRA,
                           GL_UNSIGNED_INT_8_8_8_8_REV, ioSurfaceBuffer, 0);
    glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    // Generate an FBO and bind the texture to it as a render target.
    glBindTexture(GL_TEXTURE_RECTANGLE, 0);
    glGenFramebuffers(1, &m_iosurfaceFrameBuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, m_iosurfaceFrameBuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE, m_iosurfaceTexture, 0);

    if (m_format.depthBufferSize() > 0 || m_format.stencilBufferSize() > 0) {
        glGenRenderbuffers(1, &m_iosurfaceDepthStencilBuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, m_iosurfaceDepthStencilBuffer);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, m_iosurfaceDepthStencilBuffer);

        if (m_format.stencilBufferSize() > 0)
            glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER, m_iosurfaceDepthStencilBuffer);

        glBindRenderbuffer(GL_RENDERBUFFER, m_iosurfaceDepthStencilBuffer);

        if (m_format.stencilBufferSize() > 0)
            glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8_EXT, width, height);
        else
            glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT16, width, height);
    }

    // Check for completeness and print error
    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        if (status == GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT)
            qWarning() << "QCocoaGLContext::setupIOSurfaceFBO GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT";
        else if (status == GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT)
            qWarning() << "QCocoaGLContext::setupIOSurfaceFBO GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT";
        else if (status == GL_FRAMEBUFFER_INCOMPLETE_DRAW_BUFFER)
            qWarning() << "QCocoaGLContext::setupIOSurfaceFBO GL_FRAMEBUFFER_INCOMPLETE_DRAW_BUFFER";
        else if (status == GL_FRAMEBUFFER_INCOMPLETE_READ_BUFFER)
            qWarning() << "QCocoaGLContext::setupIOSurfaceFBO GL_FRAMEBUFFER_INCOMPLETE_READ_BUFFER";
        else if (status == GL_FRAMEBUFFER_UNSUPPORTED)
            qWarning() << "QCocoaGLContext::setupIOSurfaceFBO GL_FRAMEBUFFER_UNSUPPORTED";
    }

    return (status == GL_FRAMEBUFFER_COMPLETE);
}

void QCocoaGLContext::updateIOSurfaceIfNeeded(QSize size)
{
    // Create IOSurface if null or if resize is needed
    if (!m_iosurface || IOSurfaceGetWidth(m_iosurface) != size_t(size.width())
                     || IOSurfaceGetHeight(m_iosurface) != size_t(size.height())) {

        // Release current surface
        if (m_iosurface) {
            // ### but how
            // IOSurfaceDestroy(m_iosurface)
        }

        m_iosurface = createIOSurface(size);
        if (!m_iosurface) {
            qWarning("QCococaGLContext: Unable to crate IO surface");
        }

        bool complete = createIOSurfaceFBO(m_iosurface);
        if (!complete) {
            // ### release surface
            m_iosurface = 0;
        }
    }
}

QT_END_NAMESPACE
