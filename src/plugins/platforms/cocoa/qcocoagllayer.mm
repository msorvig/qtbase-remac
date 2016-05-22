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
    m_drawFbo = 0;

    self.asynchronous = NO;

    return self;
}

- (NSOpenGLPixelFormat *)openGLPixelFormatForDisplayMask:(uint32_t)mask
{
    NSOpenGLPixelFormat *pixelFormat = 0;

    // TODO: according to docs we should use mask and create a NSOpenGLPFAScreenMask... somehow
    // NSOpenGLPFAScreenMask, CGDisplayIDToOpenGLDisplayMask(kCGDirectMainDisplay),
    Q_UNUSED(mask)

    // Use pixel format from existing context if there is one. This means we respect
    // the QSurfaceFormat configurtion created by the user.
#if 0
    QCocoaGLContext *qtContext = 0;
    if (m_window)
        qtContext = QCocoaGLContext::contextForTargetWindow(m_window->window());
    if (qtContext) {
        NSOpenGLContext *context = qtContext->nativeContext();
        if (context) {
            CGLContextObj cglContext = [context CGLContextObj];
            CGLPixelFormatObj cglPixelFormat = CGLGetPixelFormat(cglContext);
            pixelFormat = [[NSOpenGLPixelFormat alloc] initWithCGLPixelFormatObj:cglPixelFormat];
        }
    }
#endif
    // Create a default pixel format if there was no context. This is probably not what
    // was intended by user code, so we should possibly have a qWarning() here.
    if (!pixelFormat) {
        qWarning("QCocoaGLLayer openGLPixelFormatForDisplayMask: Using default pixel format");

        NSOpenGLPixelFormatAttribute attributes [] =
        {
            NSOpenGLPFADoubleBuffer,
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
    // Use existing native context if there is one.
    NSOpenGLContext *context = 0;
#if 0
    if (m_window)
        if (QCocoaGLContext *qtContext = QCocoaGLContext::contextForTargetWindow(m_window->window()))
            context = qtContext->nativeContext();
#endif
    if (!context)
        context = [[NSOpenGLContext alloc] initWithFormat:pixelFormat shareContext:nil];
    return context;
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

    // Unused: time stamps are provided by the outed DisplayLink driver
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
