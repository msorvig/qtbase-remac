#!/usr/bin/env python3
#############################################################################
##
## Copyright (C) 2013 Digia Plc and/or its subsidiary(-ies).
## Contact: http://www.qt-project.org/legal
##
## This file is part of the release tools of the Qt Toolkit.
##
## $QT_BEGIN_LICENSE:LGPL$
## Commercial License Usage
## Licensees holding valid commercial Qt licenses may use this file in
## accordance with the commercial license agreement provided with the
## Software or, alternatively, in accordance with the terms contained in
## a written agreement between you and Digia.  For licensing terms and
## conditions see http://qt.digia.com/licensing.  For further information
## use the contact form at http://qt.digia.com/contact-us.
##
## GNU Lesser General Public License Usage
## Alternatively, this file may be used under the terms of the GNU Lesser
## General Public License version 2.1 as published by the Free Software
## Foundation and appearing in the file LICENSE.LGPL included in the
## packaging of this file.  Please review the following information to
## ensure the GNU Lesser General Public License version 2.1 requirements
## will be met: http://www.gnu.org/licenses/old-licenses/lgpl-2.1.html.
##
## In addition, as a special exception, Digia gives you certain additional
## rights.  These rights are described in the Digia Qt LGPL Exception
## version 1.1, included in the file LGPL_EXCEPTION.txt in this package.
##
## GNU General Public License Usage
## Alternatively, this file may be used under the terms of the GNU
## General Public License version 3.0 as published by the Free Software
## Foundation and appearing in the file LICENSE.GPL included in the
## packaging of this file.  Please review the following information to
## ensure the GNU General Public License version 3.0 requirements will be
## met: http://www.gnu.org/copyleft/gpl.html.
##
##
## $QT_END_LICENSE$
##
#############################################################################

#regenerate all test's output

import os
import sys
import subprocess
import re

formats = ['xml', 'txt', 'xunitxml', 'lightxml']

qtver = subprocess.check_output(['qmake', '-query', 'QT_VERSION']).strip().decode('utf-8')
rootPath = os.getcwd()

isWindows = sys.platform == 'win32'

replacements = [
    (qtver, r'@INSERT_QT_VERSION_HERE@'),
    (rootPath.encode('unicode-escape').decode('utf-8'), r''),
    (r'<Duration msecs="\d+"/>', r'<Duration msecs="0"/>'),
]

extraArgs = {
    "commandlinedata": "fiveTablePasses fiveTablePasses:fiveTablePasses_data1 -v2",
    "benchlibcallgrind": "-callgrind",
    "benchlibeventcounter": "-eventcounter",
    "benchliboptions": "-eventcounter",
    "benchlibtickcounter": "-tickcounter",
    "badxml": "-eventcounter",
    "benchlibcounting": "-eventcounter",
    "printdatatags": "-datatags",
    "printdatatagswithglobaltags": "-datatags",
    "silent": "-silent",
    "verbose1": "-v1",
    "verbose2": "-v2",
}

# Replace all occurrences of searchExp in one file
def replaceInFile(file):
    import sys
    import fileinput
    for line in fileinput.input(file, inplace=1):
        for searchExp, replaceExp in replacements:
            line = re.sub(searchExp, replaceExp, line)
        sys.stdout.write(line)

def subdirs():
    for path in os.listdir('.'):
        if os.path.isdir('./' + path):
            yield path

def getTestForPath(path):
    if isWindows:
        testpath = path + '\\' + path + '.exe'
    else:
        testpath = path + '/' + path
    return testpath

def generateTestData(testname):
    print("  running " + testname)
    for format in formats:
        cmd = [getTestForPath(testname) + ' -' + format + ' ' + extraArgs.get(testname, '')]
        result = 'expected_' + testname + '.' + format
        data = subprocess.Popen(cmd, stdout=subprocess.PIPE, shell=True).communicate()[0]
        out = open(result, 'w')
        out.write(data.decode('utf-8'))
        out.close()
        replaceInFile(result)

if isWindows:
    print("This script does not work on Windows.")
    exit()

print("Generating test results for: " + qtver + " in: " + rootPath)
for path in subdirs():
    if os.path.isfile(getTestForPath(path)):
        generateTestData(path)
    else:
        print("Warning: directory " + path + " contains no test executable")