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
    void (*getProcAddress(const QByteArray &procName)) () Q_DECL_OVERRIDE;
    QSurfaceFormat format() const Q_DECL_OVERRIDE;

    static NSOpenGLPixelFormat *createPixelFormat(const QSurfaceFormat &format);
    static NSOpenGLContext *createGLContext(QSurfaceFormat format,
                                            QPlatformOpenGLContext *shareContext);
    static NSOpenGLContext *createGLContext(NSOpenGLPixelFormat *pixelFormat,
                                            NSOpenGLContext *shareContext);
    static QSurfaceFormat updateSurfaceFormat(NSOpenGLContext *context, QSurfaceFormat requestedFormat);

    NSOpenGLContext *nativeContext() const;
    QVariant nativeHandle() const;
protected:
    QSurfaceFormat m_format;
    NSOpenGLContext *m_context;
    QWindow *m_targetWindow;
};

// Context implementation for when QCocoaWindow is backed by a NSView
// with an attached NSOpenGLContext.
class QCocoaGLViewContext : public QCocoaGLContext
{
public:
    QCocoaGLViewContext(const QSurfaceFormat &format, QPlatformOpenGLContext *share,
                        const QVariant &nativeHandle, QWindow *targetWindow);
    ~QCocoaGLViewContext();

    void swapBuffers(QPlatformSurface *surface) Q_DECL_OVERRIDE;
    bool makeCurrent(QPlatformSurface *surface) Q_DECL_OVERRIDE;
    void doneCurrent() Q_DECL_OVERRIDE;
    bool isSharing() const Q_DECL_OVERRIDE;
    bool isValid() const Q_DECL_OVERRIDE;

    void update();
    void windowWasHidden();
private:
    void setActiveWindow(QWindow *window);

    NSOpenGLContext *m_shareContext;
    QPointer<QWindow> m_currentWindow;
};

// Context implementation for when QCocoaWindow is backed by a NSOpenGLLayer
class QCocoaGLLayerContext : public QCocoaGLContext
{
public:
    QCocoaGLLayerContext(const QSurfaceFormat &format, QPlatformOpenGLContext *share,
                         const QVariant &nativeHandle, QWindow *targetWindow);

    void swapBuffers(QPlatformSurface *surface) Q_DECL_OVERRIDE;
    GLuint defaultFramebufferObject(QPlatformSurface *surface) const Q_DECL_OVERRIDE;
    bool makeCurrent(QPlatformSurface *surface) Q_DECL_OVERRIDE;
    void doneCurrent() Q_DECL_OVERRIDE;
    bool isSharing() const Q_DECL_OVERRIDE;
    bool isValid() const Q_DECL_OVERRIDE;

private:
    QPlatformOpenGLContext *m_shareContext;
    bool m_isValid;
};

QT_END_NAMESPACE

#endif // QCOCOAGLCONTEXT_H
