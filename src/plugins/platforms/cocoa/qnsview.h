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

#ifndef QNSVIEW_H
#define QNSVIEW_H

#include <AppKit/AppKit.h>

#include <QtCore/QPointer>
#include <QtGui/QImage>
#include <QtGui/QAccessible>

#include "private/qcore_mac_p.h"

QT_BEGIN_NAMESPACE
class QCocoaWindow;
class QCocoaBackingStore;
class QCocoaGLViewContext;
QT_END_NAMESPACE

Q_FORWARD_DECLARE_OBJC_CLASS(QT_MANGLE_NAMESPACE(QNSViewMouseMoveHelper));

@interface QT_MANGLE_NAMESPACE(QNSView) : NSView <NSTextInputClient> {
    QCocoaBackingStore* m_backingStore;
    QPoint m_backingStoreOffset;
    QRegion m_maskRegion;
    CGImageRef m_maskImage;
    bool m_shouldInvalidateWindowShadow;
    QPointer<QWindow> m_window;
    QCocoaWindow *m_platformWindow;
    NSTrackingArea *m_trackingArea;
    Qt::MouseButtons m_buttons;
    Qt::MouseButtons m_frameStrutButtons;
    QString m_composingText;
    bool m_sendKeyEvent;
    QStringList *currentCustomDragTypes;
    bool m_sendUpAsRightButton;
    Qt::KeyboardModifiers currentWheelModifiers;
#ifndef QT_NO_OPENGL
    QCocoaGLViewContext *m_glContext;
    bool m_shouldSetGLContextinDrawRect;
#endif

    CVDisplayLinkRef m_displayLink;
    NSTimer *m_displayLinkStopTimer;
    int m_displayLinkSerial;
    int m_displayLinkSerialAtTimerSchedule;
    @public bool m_requestUpdateCalled;

    NSString *m_inputSource;
    QT_MANGLE_NAMESPACE(QNSViewMouseMoveHelper) *m_mouseMoveHelper;
    bool m_resendKeyEvent;
    bool m_scrolling;
    bool m_exposedOnMoveToWindow;
    QHash<int, bool> m_acceptedKeyDowns;
    QSet<Qt::MouseButton> m_acceptedMouseDowns;
    bool m_inDrawRect;
}

- (id)init;
- (id)initWithQWindow:(QWindow *)window platformWindow:(QCocoaWindow *) platformWindow;
- (void) clearQWindowPointers;
#ifndef QT_NO_OPENGL
- (void)setQCocoaGLViewContext:(QCocoaGLViewContext *)context;
#endif
- (void)flushBackingStore:(QCocoaBackingStore *)backingStore region:(const QRegion &)region offset:(QPoint)offset;
- (void)clearBackingStore:(QCocoaBackingStore *)backingStore;
- (void)setMaskRegion:(const QRegion *)region;
- (void)invalidateWindowShadowIfNeeded;
- (void)drawRect:(NSRect)dirtyRect;
- (void)updateGeometry;
- (void)notifyWindowStateChanged:(Qt::WindowState)newState;
- (void)windowNotification : (NSNotification *) windowNotification;
- (void)notifyWindowWillZoom:(BOOL)willZoom;
- (void)viewDidHide;
- (void)viewDidUnhide;

- (BOOL)isFlipped;
- (BOOL)acceptsFirstResponder;
- (BOOL)becomeFirstResponder;
- (BOOL)hasMask;
- (BOOL)isOpaque;

- (void)convertFromScreen:(NSPoint)mouseLocation toWindowPoint:(QPointF *)qtWindowPoint andScreenPoint:(QPointF *)qtScreenPoint;

- (void)resetMouseButtons;

- (bool)handleMouseEvent:(NSEvent *)theEvent;
- (void)mouseDown:(NSEvent *)theEvent;
- (void)mouseDragged:(NSEvent *)theEvent;
- (void)mouseUp:(NSEvent *)theEvent;
- (bool)mouseMovedImpl:(NSEvent *)theEvent;
- (void)mouseEnteredImpl:(NSEvent *)theEvent;
- (void)mouseExitedImpl:(NSEvent *)theEvent;
- (void)cursorUpdateImpl:(NSEvent *)theEvent;
- (void)rightMouseDown:(NSEvent *)theEvent;
- (void)rightMouseDragged:(NSEvent *)theEvent;
- (void)rightMouseUp:(NSEvent *)theEvent;
- (void)otherMouseDown:(NSEvent *)theEvent;
- (void)otherMouseDragged:(NSEvent *)theEvent;
- (void)otherMouseUp:(NSEvent *)theEvent;
- (void)handleFrameStrutMouseEvent:(NSEvent *)theEvent;

- (void)handleTabletEvent: (NSEvent *)theEvent;
- (void)tabletPoint: (NSEvent *)theEvent;
- (void)tabletProximity: (NSEvent *)theEvent;

- (int) convertKeyCode : (QChar)keyCode;
+ (Qt::KeyboardModifiers) convertKeyModifiers : (ulong)modifierFlags;
- (bool)handleKeyEvent:(NSEvent *)theEvent eventType:(int)eventType;
- (void)keyDown:(NSEvent *)theEvent;
- (void)keyUp:(NSEvent *)theEvent;
- (BOOL)performKeyEquivalent:(NSEvent *)theEvent;

- (void)registerDragTypes;
- (NSDragOperation)handleDrag:(id <NSDraggingInfo>)sender;
- (void) requestUpdate;
- (void) requestUpdateWithRect:(QRect)rect;
- (void) requestUpdateWithRegion:(QRegion)region;

@end

QT_NAMESPACE_ALIAS_OBJC_CLASS(QNSView);

#endif //QNSVIEW_H
