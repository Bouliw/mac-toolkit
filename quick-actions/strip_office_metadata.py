#!/usr/bin/python3
# Removes author, last editor, company, template and dates from a Word/Excel/PowerPoint file.
import re
import sys
import zipfile

src, dst = sys.argv[1], sys.argv[2]

CORE = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" '
        'xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
        '</cp:coreProperties>')
CUSTOM = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
          '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/custom-properties" '
          'xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"></Properties>')
APP_TAGS = r'(Company|Manager|Template|HyperlinkBase|TotalTime)'

with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, 'w', zipfile.ZIP_DEFLATED) as zout:
    for item in zin.infolist():
        data = zin.read(item.filename)
        if item.filename == 'docProps/core.xml':
            data = CORE.encode()
        elif item.filename == 'docProps/custom.xml':
            data = CUSTOM.encode()
        elif item.filename == 'docProps/app.xml':
            s = data.decode('utf-8')
            s = re.sub(rf'<{APP_TAGS}>.*?</\1>', '', s, flags=re.S)
            s = re.sub(rf'<{APP_TAGS}\s*/>', '', s)
            data = s.encode('utf-8')
        zout.writestr(item, data)
