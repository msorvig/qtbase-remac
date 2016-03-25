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

@implementation QCocoaOpenGLLayer

- (id)initWithQNSView:(QNSView *)qtView andQCocoaWindow:(QCocoaWindow *)qtWindow
{
    [super init];
    m_view = qtView;
    m_window = qtWindow;

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
    QCocoaGLContext *qtContext = QCocoaGLContext::contextForTargetWindow(m_window->window());
    if (qtContext) {
        NSOpenGLContext *context = qtContext->nativeContext();
        if (context) {
            CGLContextObj cglContext = [context CGLContextObj];
            CGLPixelFormatObj cglPixelFormat = CGLGetPixelFormat(cglContext);
            pixelFormat = [[NSOpenGLPixelFormat alloc] initWithCGLPixelFormatObj:cglPixelFormat];
        }
    }

    // Create a default pixel format if there was no context. This is probably not what
    // was intended by user code, so we should possibly have a qWarning() here.
    if (!pixelFormat) {
        qWarning("QCocoaOpenGLLayer openGLPixelFormatForDisplayMask: Using default pixel format");

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
    if (QCocoaGLContext *qtContext = QCocoaGLContext::contextForTargetWindow(m_window->window()))
        context = qtContext->nativeContext();
    if (!context)
        context = [[NSOpenGLContext alloc] initWithFormat:pixelFormat shareContext:nil];
    return context;
}

- (void)drawInOpenGLContext:(NSOpenGLContext *)context
                pixelFormat:(NSOpenGLPixelFormat *)pixelFormat
               forLayerTime:(CFTimeInterval)timeInterval
                displayTime:(const CVTimeStamp *)timeStamp
{
    Q_UNUSED(context);
    Q_UNUSED(pixelFormat);
    Q_UNUSED(timeInterval);
    Q_UNUSED(timeStamp);

    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &m_drawFbo);
//    qDebug() << "";
//    qDebug() << "drawInOpenGLContext" << "draw fbo is" << m_drawFbo;

    QRect dirty(0,0, 999, 999);
    [m_view sendUpdateRequest:dirty];

    [m_view drawBackingStoreUsingQOpenGL];
}

@end
