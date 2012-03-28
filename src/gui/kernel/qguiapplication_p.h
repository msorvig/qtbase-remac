/****************************************************************************
**
** Copyright (C) 2012 Nokia Corporation and/or its subsidiary(-ies).
** Contact: http://www.qt-project.org/
**
** This file is part of the QtGui module of the Qt Toolkit.
**
** $QT_BEGIN_LICENSE:LGPL$
** GNU Lesser General Public License Usage
** This file may be used under the terms of the GNU Lesser General Public
** License version 2.1 as published by the Free Software Foundation and
** appearing in the file LICENSE.LGPL included in the packaging of this
** file. Please review the following information to ensure the GNU Lesser
** General Public License version 2.1 requirements will be met:
** http://www.gnu.org/licenses/old-licenses/lgpl-2.1.html.
**
** In addition, as a special exception, Nokia gives you certain additional
** rights. These rights are described in the Nokia Qt LGPL Exception
** version 1.1, included in the file LGPL_EXCEPTION.txt in this package.
**
** GNU General Public License Usage
** Alternatively, this file may be used under the terms of the GNU General
** Public License version 3.0 as published by the Free Software Foundation
** and appearing in the file LICENSE.GPL included in the packaging of this
** file. Please review the following information to ensure the GNU General
** Public License version 3.0 requirements will be met:
** http://www.gnu.org/copyleft/gpl.html.
**
** Other Usage
** Alternatively, this file may be used in accordance with the terms and
** conditions contained in a signed written agreement between you and Nokia.
**
**
**
**
**
**
** $QT_END_LICENSE$
**
****************************************************************************/

#ifndef QGUIAPPLICATION_QPA_P_H
#define QGUIAPPLICATION_QPA_P_H

#include <QtGui/qguiapplication.h>

#include <QtCore/QPointF>
#include <QtCore/private/qcoreapplication_p.h>

#include <QtCore/private/qthread_p.h>

#include <QWindowSystemInterface>
#include "private/qwindowsysteminterface_qpa_p.h"
#include "private/qshortcutmap_p.h"

#include "qplatformdrag_qpa.h"

QT_BEGIN_HEADER

QT_BEGIN_NAMESPACE

class QPlatformIntegration;
class QPlatformTheme;
struct QDrawHelperGammaTables;

class Q_GUI_EXPORT QGuiApplicationPrivate : public QCoreApplicationPrivate
{
    Q_DECLARE_PUBLIC(QGuiApplication)
public:
    QGuiApplicationPrivate(int &argc, char **argv, int flags);
    ~QGuiApplicationPrivate();

    void createPlatformIntegration();
    void createEventDispatcher();
    void setEventDispatcher(QAbstractEventDispatcher *eventDispatcher);

    virtual void notifyLayoutDirectionChange();
    virtual void notifyActiveWindowChange(QWindow *previous);

    virtual bool shouldQuit();

    static Qt::KeyboardModifiers modifier_buttons;
    static Qt::MouseButtons mouse_buttons;

    static QPlatformIntegration *platform_integration;

    static QPlatformIntegration *platformIntegration()
    { return platform_integration; }

    static QPlatformTheme *platform_theme;

    static QPlatformTheme *platformTheme()
    { return platform_theme; }

    static QAbstractEventDispatcher *qt_qpa_core_dispatcher()
    { return QCoreApplication::instance()->d_func()->threadData->eventDispatcher; }

    static void processMouseEvent(QWindowSystemInterfacePrivate::MouseEvent *e);
    static void processKeyEvent(QWindowSystemInterfacePrivate::KeyEvent *e);
    static void processWheelEvent(QWindowSystemInterfacePrivate::WheelEvent *e);
    static void processTouchEvent(QWindowSystemInterfacePrivate::TouchEvent *e);

    static void processCloseEvent(QWindowSystemInterfacePrivate::CloseEvent *e);

    static void processGeometryChangeEvent(QWindowSystemInterfacePrivate::GeometryChangeEvent *e);

    static void processEnterEvent(QWindowSystemInterfacePrivate::EnterEvent *e);
    static void processLeaveEvent(QWindowSystemInterfacePrivate::LeaveEvent *e);

    static void processActivatedEvent(QWindowSystemInterfacePrivate::ActivatedWindowEvent *e);
    static void processWindowStateChangedEvent(QWindowSystemInterfacePrivate::WindowStateChangedEvent *e);

    static void processWindowSystemEvent(QWindowSystemInterfacePrivate::WindowSystemEvent *e);

    static void reportScreenOrientationChange(QScreen *screen);
    static void reportScreenOrientationChange(QWindowSystemInterfacePrivate::ScreenOrientationEvent *e);
    static void reportGeometryChange(QWindowSystemInterfacePrivate::ScreenGeometryEvent *e);
    static void reportAvailableGeometryChange(QWindowSystemInterfacePrivate::ScreenAvailableGeometryEvent *e);
    static void reportLogicalDotsPerInchChange(QWindowSystemInterfacePrivate::ScreenLogicalDotsPerInchEvent *e);
    static void processThemeChanged(QWindowSystemInterfacePrivate::ThemeChangeEvent *tce);

    static void processMapEvent(QWindowSystemInterfacePrivate::MapEvent *e);
    static void processUnmapEvent(QWindowSystemInterfacePrivate::UnmapEvent *e);

    static void processExposeEvent(QWindowSystemInterfacePrivate::ExposeEvent *e);

    static QPlatformDragQtResponse processDrag(QWindow *w, const QMimeData *dropData, const QPoint &p, Qt::DropActions supportedActions);
    static QPlatformDropQtResponse processDrop(QWindow *w, const QMimeData *dropData, const QPoint &p, Qt::DropActions supportedActions);

    static bool processNativeEvent(QWindow *window, const QByteArray &eventType, void *message, long *result);

    static inline Qt::Alignment visualAlignment(Qt::LayoutDirection direction, Qt::Alignment alignment)
    {
        if (!(alignment & Qt::AlignHorizontal_Mask))
            alignment |= Qt::AlignLeft;
        if ((alignment & Qt::AlignAbsolute) == 0 && (alignment & (Qt::AlignLeft | Qt::AlignRight))) {
            if (direction == Qt::RightToLeft)
                alignment ^= (Qt::AlignLeft | Qt::AlignRight);
            alignment |= Qt::AlignAbsolute;
        }
        return alignment;
    }

    static void emitLastWindowClosed();

    QPixmap getPixmapCursor(Qt::CursorShape cshape);

    void q_updateFocusObject(QObject *object);

    static QGuiApplicationPrivate *instance() { return self; }

    static QString *platform_name;

    QWindowList modalWindowList;
    static void showModalWindow(QWindow *window);
    static void hideModalWindow(QWindow *window);
    virtual bool isWindowBlocked(QWindow *window, QWindow **blockingWindow = 0) const;

    static Qt::MouseButtons buttons;
    static ulong mousePressTime;
    static Qt::MouseButton mousePressButton;
    static int mousePressX;
    static int mousePressY;
    static int mouse_double_click_distance;
    static QPointF lastCursorPosition;

#ifndef QT_NO_CLIPBOARD
    static QClipboard *qt_clipboard;
#endif

    static QPalette *app_pal;

    static QWindowList window_list;
    static QWindow *focus_window;

#ifndef QT_NO_CURSOR
    QList<QCursor> cursor_list;
#endif
    static QList<QScreen *> screen_list;

    static QFont *app_font;

    QStyleHints *styleHints;
    static bool obey_desktop_settings;
    QInputMethod *inputMethod;

    static QList<QObject *> generic_plugin_list;
#ifndef QT_NO_SHORTCUT
    QShortcutMap shortcutMap;
#endif

    struct ActiveTouchPointsKey {
        ActiveTouchPointsKey(QTouchDevice *dev, int id) : device(dev), touchPointId(id) { }
        QTouchDevice *device;
        int touchPointId;
    };
    struct ActiveTouchPointsValue {
        QWeakPointer<QWindow> window;
        QWeakPointer<QObject> target;
        QTouchEvent::TouchPoint touchPoint;
    };
    QHash<ActiveTouchPointsKey, ActiveTouchPointsValue> activeTouchPoints;
    QEvent::Type lastTouchType;
    struct SynthesizedMouseData {
        SynthesizedMouseData(const QPointF &p, const QPointF &sp, QWindow *w)
            : pos(p), screenPos(sp), window(w) { }
        QPointF pos;
        QPointF screenPos;
        QWeakPointer<QWindow> window;
    };
    QHash<QWindow *, SynthesizedMouseData> synthesizedMousePoints;

    const QDrawHelperGammaTables *gammaTables();

protected:
    virtual void notifyThemeChanged();

private:
    void init();

    static QGuiApplicationPrivate *self;
    static QTouchDevice *m_fakeTouchDevice;
    static int m_fakeMouseSourcePointId;
    QAtomicPointer<QDrawHelperGammaTables> m_gammaTables;
};

Q_GUI_EXPORT uint qHash(const QGuiApplicationPrivate::ActiveTouchPointsKey &k);

Q_GUI_EXPORT bool operator==(const QGuiApplicationPrivate::ActiveTouchPointsKey &a,
                             const QGuiApplicationPrivate::ActiveTouchPointsKey &b);

QT_END_NAMESPACE

QT_END_HEADER

#endif // QGUIAPPLICATION_QPA_P_H
