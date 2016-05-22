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

#ifndef QCOCOAGLCONTEXT_H
#define QCOCOAGLCONTEXT_H

#include <QtCore/QPointer>
#include <qpa/qplatformopenglcontext.h>
#include <QtGui/QOpenGLContext>
#include <QtGui/QWindow>

#undef slots
#include <AppKit/AppKit.h>

QT_BEGIN_NAMESPACE

class QCocoaGLContext : public QPlatformOpenGLContext
{

public:
    QCocoaGLContext(QOpenGLContext *context, QWindow *targetWindow);
    ~QCocoaGLContext();

    // QPlatformOpenGLContext API
    QSurfaceFormat format() const Q_DECL_OVERRIDE;
    void swapBuffers(QPlatformSurface *surface) Q_DECL_OVERRIDE;
    GLuint defaultFramebufferObject(QPlatformSurface *surface) const Q_DECL_OVERRIDE;
    bool makeCurrent(QPlatformSurface *surface) Q_DECL_OVERRIDE;
    void doneCurrent() Q_DECL_OVERRIDE;
    bool isSharing() const Q_DECL_OVERRIDE;
    bool isValid() const Q_DECL_OVERRIDE;
    QFunctionPointer getProcAddress(const char *procName) Q_DECL_OVERRIDE;

    // Helpers
    static QCocoaGLContext *contextForTargetWindow(QWindow *window);
    static NSOpenGLPixelFormat *createPixelFormat(const QSurfaceFormat &format);
    static NSOpenGLContext *createGLContext(QSurfaceFormat format,
                                            QPlatformOpenGLContext *shareContext);
    static NSOpenGLContext *createGLContext(NSOpenGLPixelFormat *pixelFormat,
                                            NSOpenGLContext *shareContext);
    static QSurfaceFormat updateSurfaceFormat(NSOpenGLContext *context, QSurfaceFormat requestedFormat);

    // Misc
    void update();
    void windowWasHidden();
    NSOpenGLContext *nativeContext() const;
    QVariant nativeHandle() const;
    void setActiveWindow(QWindow *window);

private:
    bool m_isLayerContext;
    bool m_isValid;
    QSurfaceFormat m_format;
    NSOpenGLContext *m_context;
    NSOpenGLContext *m_shareContext;
    QPointer<QWindow> m_currentWindow;
    QPointer<QWindow> m_targetWindow;
};

QT_END_NAMESPACE

#endif // QCOCOAGLCONTEXT_H
