/****************************************************************************
**
** Copyright (C) 2015 The Qt Company Ltd.
** Contact: http://www.qt.io/licensing/
**
** This file is part of the QtGui module of the Qt Toolkit.
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

#include "qimage.h"

#import <Foundation/Foundation.h>
#import <AppKit/Appkit.h>

QT_BEGIN_NAMESPACE

/*!
    Creates a \c CGImage equivalent to the QImage \a image. Returns a
    \c CGImageRef handle.

    The returned CGImageRef owns a copy of the QImage. The image data itself
    is normally not copied. Writing to the original QImage will cause it to
    detach; the CGImage will not be changed, preserving its immutatbility.
    
    The following image formats are supported, and will be mapped to 
    a corresponding native image type:
        Qt                              Native
        Format_ARGB32                   kCGImageAlphaFirst | kCGBitmapByteOrder32Host;
        Format_RGB32                    kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Host
        Format_RGB888                   kCGImageAlphaNone | kCGBitmapByteOrder32Big
        Format_RGBA8888_Premultiplied   kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
        Format_RGBA8888                 kCGImageAlphaLast | kCGBitmapByteOrder32Big
        Format_RGBX8888                 kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big;
        Format_ARGB32_Premultiplied     kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host

    Other formats will be converted to Format_ARGB32_Premultiplied, at the cost
    of converting the QImage data.
    
    It is the caller's responsibility to release the \c CGImageRef
    after use. This will also decrement the QImage data reference count, 
    possibly deleting it.

    \sa toNSImage()
*/
CGImageRef QImage::toCGImage() const
{
    if (isNull())
        return 0;

    QImage image = *this;

    // Match image formats.
    uint cgflags = kCGImageAlphaNone;
    switch (image.format()) {
    case QImage::Format_ARGB32:
        cgflags = kCGImageAlphaFirst | kCGBitmapByteOrder32Host;
        break;
    case QImage::Format_RGB32:
        cgflags = kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Host;
        break;
    case QImage::Format_RGB888:
        cgflags = kCGImageAlphaNone | kCGBitmapByteOrder32Big;
        break;
    case QImage::Format_RGBA8888_Premultiplied:
        cgflags = kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big;
        break;
    case QImage::Format_RGBA8888:
        cgflags = kCGImageAlphaLast | kCGBitmapByteOrder32Big;
        break;
    case QImage::Format_RGBX8888:
        cgflags = kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big;
        break;
    default:
        // Everything not recognized explicitly is converted to ARGB32_Premultiplied.
        image = this->convertToFormat(QImage::Format_ARGB32_Premultiplied);
        // no break;
    case QImage::Format_ARGB32_Premultiplied:
        cgflags = kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host;
        break;
    }

    // Create a data provider that owns a copy of the QImage and references the image data.
    CGDataProviderRef dataProvider = 
        CGDataProviderCreateWithData(new QImage(image), image.bits(), image.byteCount(),
                                     [](void *image, const void *, size_t) 
                                     { delete reinterpret_cast<QImage *>(image); });

    // Use a generic 'don't care' no-conversion color space.
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();

    const size_t bitsPerComponent = 8;
    const size_t bitsPerPixel = 32;
    const CGFloat *decode = 0;
    const bool shouldInterpolate = false;

    CGImageRef cgImage = CGImageCreate(image.width(), image.height(),
                                       bitsPerComponent, bitsPerPixel, image.bytesPerLine(),
                                       colorSpace, cgflags, dataProvider,
                                       decode, shouldInterpolate, kCGRenderingIntentDefault);
    CFRelease(dataProvider);
    CFRelease(colorSpace);
    return cgImage;
}

/*!
    Creates a \c NSImage equivalent to the QImage \a image. Returns a
    \c NSImage *. See toCGImage() for details.
    
    The NSImage (point) size is set to be the device independent size
    of the QImage, effectivly size() / devicePixelRatio().

    \sa toCGImage()
*/
NSImage *QImage::toNSImage() const
{
    CGImageRef cgImage = this->toCGImage();
    NSSize deviceIndependentSize = { width() / devicePixelRatio(), height() / devicePixelRatio() };
    return [[NSImage alloc] initWithCGImage:cgImage size:deviceIndependentSize];
}

QT_END_NAMESPACE
