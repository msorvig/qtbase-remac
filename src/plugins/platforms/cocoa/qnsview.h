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

#ifndef QNSVIEW_H
#define QNSVIEW_H

#include <AppKit/AppKit.h>

#include <QtCore/QMutex>
#include <QtCore/QPointer>
#include <QtCore/QSet>
#include <QtCore/QWaitCondition>
#include <QtGui/QImage>
#include <QtGui/QAccessible>

#include "private/qcore_mac_p.h"

QT_BEGIN_NAMESPACE
class QCocoaWindow;
class QCocoaBackingStore;
class QCocoaGLContext;
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
    Qt::MouseButtons m_acceptedMouseDowns;
    Qt::MouseButtons m_frameStrutButtons;
    QString m_composingText;
    bool m_sendKeyEvent;
    QStringList *currentCustomDragTypes;
    bool m_sendUpAsRightButton;
    Qt::KeyboardModifiers currentWheelModifiers;
#ifndef QT_NO_OPENGL
    QCocoaGLContext *m_glContext;
    bool m_shouldSetGLContextinDrawRect;
#endif

    bool m_displayLinkEnable;
    CVDisplayLinkRef m_displayLink;
    NSTimer *m_displayLinkStopTimer;
    int m_displayLinkSerial;
    int m_displayLinkSerialAtTimerSchedule;
    bool m_requestUpdateCalled;
    @public QMutex m_displayLinkMutex;
    QWaitCondition m_displayLinkWait;
    @public const CVTimeStamp *m_displayLinkNowTime;
    @public const CVTimeStamp *m_displayLinkOutputTime;
    bool m_displayLinkDisable;
    bool m_isDisplayLinkUpdate;
    QRegion m_displayLinkDirty;

    NSString *m_inputSource;
    QT_MANGLE_NAMESPACE(QNSViewMouseMoveHelper) *m_mouseMoveHelper;
    bool m_resendKeyEvent;
    bool m_scrolling;
    bool m_updatingDrag;
    bool m_exposedOnMoveToWindow;
    NSEvent *m_currentlyInterpretedKeyEvent;
    bool m_isMenuView;
    QHash<int, bool> m_acceptedKeyDowns;
    QSet<Qt::MouseButton> m_acceptedMouseDowns;
    bool m_inDrawRect;
    bool m_inFlushBackingStore;
    @public bool m_ownsQWindow;
}

- (id)init;
- (id)initWithQWindow:(QWindow *)window platformWindow:(QCocoaWindow *) platformWindow;
- (void) clearQWindowPointers;
#ifndef QT_NO_OPENGL
- (void)setQCocoaGLContext:(QCocoaGLContext *)context;
#endif
- (void)flushBackingStore:(QCocoaBackingStore *)backingStore region:(const QRegion &)region offset:(QPoint)offset;
- (void)clearBackingStore:(QCocoaBackingStore *)backingStore;
- (void)setMaskRegion:(const QRegion *)region;
- (void)invalidateWindowShadowIfNeeded;
- (void)drawRect:(NSRect)dirtyRect;
- (void)drawBackingStoreUsingCoreGraphics:(NSRect)dirtyRect;
- (void)drawBackingStoreUsingQOpenGL;
- (void)updateGeometry;
- (void)notifyWindowStateChanged:(Qt::WindowState)newState;
- (void)windowNotification : (NSNotification *) windowNotification;
- (void)notifyWindowWillZoom:(BOOL)willZoom;
- (void)textInputContextKeyboardSelectionDidChangeNotification : (NSNotification *) textInputContextKeyboardSelectionDidChangeNotification;
- (void)viewDidHide;
- (void)viewDidUnhide;
- (void)removeFromSuperview;

- (BOOL)isFlipped;
- (BOOL)acceptsFirstResponder;
- (BOOL)becomeFirstResponder;
- (BOOL)hasMask;
- (BOOL)isOpaque;

- (void)convertFromScreen:(NSPoint)mouseLocation toWindowPoint:(QPointF *)qtWindowPoint andScreenPoint:(QPointF *)qtScreenPoint;

- (void)resetMouseButtons;

- (void)handleMouseEvent:(NSEvent *)theEvent;
- (bool)handleMouseDownEvent:(NSEvent *)theEvent;
- (bool)handleMouseDraggedEvent:(NSEvent *)theEvent;
- (bool)handleMouseUpEvent:(NSEvent *)theEvent;
- (void)mouseDown:(NSEvent *)theEvent;
- (void)mouseDragged:(NSEvent *)theEvent;
- (void)mouseUp:(NSEvent *)theEvent;
- (void)mouseMovedImpl:(NSEvent *)theEvent;
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

- (bool)handleTabletEvent: (NSEvent *)theEvent;
- (void)tabletPoint: (NSEvent *)theEvent;
- (void)tabletProximity: (NSEvent *)theEvent;

- (int) convertKeyCode : (QChar)keyCode;
+ (Qt::KeyboardModifiers) convertKeyModifiers : (ulong)modifierFlags;
- (bool)handleKeyEvent:(NSEvent *)theEvent eventType:(int)eventType;
- (void)keyDown:(NSEvent *)theEvent;
- (void)keyUp:(NSEvent *)theEvent;

- (void)registerDragTypes;
- (NSDragOperation)handleDrag:(id <NSDraggingInfo>)sender;
- (void) requestUpdate;
- (void) requestUpdateWithRect:(QRect)rect;
- (void) requestUpdateWithRegion:(QRegion)region;
- (void) sendUpdateRequest:(QRect)rect;

- (void) triggerUpdateRequest:(const CVTimeStamp *) now output:(const CVTimeStamp *)target;

@end

QT_NAMESPACE_ALIAS_OBJC_CLASS(QNSView);

#endif //QNSVIEW_H
