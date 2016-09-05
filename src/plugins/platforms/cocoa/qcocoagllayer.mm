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
#include "qcocoagllayer.h"

#include <QtCore/qdebug.h>

#include "qnsview.h"
#include "qcocoawindow.h"
#include "qcocoaglcontext.h"

#include <OpenGL.h>
#include <gl.h>

@implementation QCocoaGLLayer

- (id)initWithQNSView:(QNSView *)qtView andQCocoaWindow:(QCocoaWindow *)qtWindow
{
    [super init];

    m_view = qtView;
    m_window = qtWindow;
    m_context = nil;
    m_contextWasInitialized = false;
    m_drawFbo = 0;

    self.asynchronous = NO;

    return self;
}

- (void)dealloc
{
    [m_context release];
}

- (NSOpenGLPixelFormat *)openGLPixelFormatForDisplayMask:(uint32_t)mask
{
    NSOpenGLPixelFormat *pixelFormat = 0;

    // TODO: according to docs we should use mask and create a NSOpenGLPFAScreenMask... somehow
    // NSOpenGLPFAScreenMask, CGDisplayIDToOpenGLDisplayMask(kCGDirectMainDisplay),
    Q_UNUSED(mask)

    // Get the native OpenGL context for the window. The window -> context
    // accociation is made at platform context creation time, if QOpenGLContext
    // user code has made the call to set which window the context will be used
    // for. If no context is found the then the layers falls back to using a
    // default context. This most likely won't work so print a warning.
    if (!m_contextWasInitialized) {
        m_contextWasInitialized = true;
        if (m_window) {
            QCocoaGLContext *qtContext = QCocoaGLContext::contextForTargetWindow(m_window->window());
            if (qtContext) {
                m_context = qtContext->nativeContext();
                [m_context retain];
            }
        }
        if (!m_context)
            qWarning("QCocoaGLLayer: OpenGL context not set, using default context");
    }

    // Use the pixel format from existing context if there is one.
    if (m_context) {
        CGLContextObj cglContext = [m_context CGLContextObj];
        CGLPixelFormatObj cglPixelFormat = CGLGetPixelFormat(cglContext);
        pixelFormat = [[NSOpenGLPixelFormat alloc] initWithCGLPixelFormatObj:cglPixelFormat];
    }

    // Create a default pixel format if there was no context.a qWarning() here.
    if (!pixelFormat) {
        NSOpenGLPixelFormatAttribute attributes [] =
        {
            NSOpenGLPFANoRecovery,
            NSOpenGLPFAAccelerated,
            0
        };
        pixelFormat = [[NSOpenGLPixelFormat alloc] initWithAttributes:attributes];
    }

    return pixelFormat;
}

- (NSOpenGLContext *)openGLContextForPixelFormat:(NSOpenGLPixelFormat *)pixelFormat
{
    // Use the existing native context if there is one.
    if (m_context)
        return m_context;

    return [[NSOpenGLContext alloc] initWithFormat:pixelFormat shareContext:nil];
}

- (void)drawInOpenGLContext:(NSOpenGLContext *)context
                pixelFormat:(NSOpenGLPixelFormat *)pixelFormat
               forLayerTime:(CFTimeInterval)timeInterval
                displayTime:(const CVTimeStamp *)timeStamp
{

    // Unused: assume context does not change from the one provided in
    // the init functions.
    Q_UNUSED(context);
    Q_UNUSED(pixelFormat);

    // Unused: time stamps are provided by the outer DisplayLink driver
    Q_UNUSED(timeInterval);
    Q_UNUSED(timeStamp);

    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &m_drawFbo);
    [m_view sendUpdateRequest];
    m_drawFbo = 0;
}

- (GLint)drawFbo
{
    return m_drawFbo;
}

@end

QCocoaGLLayer *qcocoaopengllayer_cast(CALayer *layer)
{
    if ([layer isKindOfClass:[QCocoaGLLayer class]])
        return static_cast<QCocoaGLLayer *>(layer);
    return 0;
}
