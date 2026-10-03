#!/usr/bin/python3
# Builds an (unsigned) Share-menu shortcut: the shared links, and the shared item itself,
# are inserted into the shell command as two text arguments.
# Usage: shortcut.py <script> <output.shortcut>
import os
import plistlib
import sys
import uuid

script, output = sys.argv[1], sys.argv[2]
home = os.path.expanduser("~")
if script.startswith(home + "/"):
    script = "$HOME" + script[len(home):]
u1, u2 = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()

# each U+FFFC is replaced at run time by a shortcut variable
# run in the foreground: Shortcuts kills whatever is still running once the shortcut ends (a download
# simply runs while the shortcut shows its progress; Send to TV hands the TV wake-up over to launchd)
head = f'/bin/zsh "{script}" \''
command = head + "\ufffc' '\ufffc' >/dev/null 2>&1"


def offset(text):  # Shortcuts counts positions in UTF-16 code units
    return len(text.encode("utf-16-le")) // 2


p1 = offset(head)
p2 = offset(head + "\ufffc' '")

shortcut = {
    "WFWorkflowClientVersion": "3300.0.4",
    "WFWorkflowMinimumClientVersion": 900,
    "WFWorkflowMinimumClientVersionString": "900",
    "WFWorkflowIcon": {"WFWorkflowIconStartColor": 4282601983, "WFWorkflowIconGlyphNumber": 61440},
    "WFWorkflowImportQuestions": [],
    "WFWorkflowTypes": ["ActionExtension"],
    "WFWorkflowInputContentItemClasses": ["WFURLContentItem", "WFSafariWebPageContentItem", "WFStringContentItem"],
    "WFWorkflowOutputContentItemClasses": [],
    "WFWorkflowHasShortcutInputVariables": True,
    "WFWorkflowNoInputBehavior": {"Name": "WFWorkflowNoInputBehaviorGetClipboard", "Parameters": {}},
    "WFWorkflowActions": [
        {"WFWorkflowActionIdentifier": "is.workflow.actions.detect.link",
         "WFWorkflowActionParameters": {
             "UUID": u1,
             "WFInput": {"Value": {"Type": "ExtensionInput"}, "WFSerializationType": "WFTextTokenAttachment"}}},
        {"WFWorkflowActionIdentifier": "is.workflow.actions.runshellscript",
         "WFWorkflowActionParameters": {
             "UUID": u2,
             "InputMode": "to stdin",
             "Shell": "/bin/zsh",
             "Script": {
                 "Value": {
                     "string": command,
                     "attachmentsByRange": {
                         f"{{{p1}, 1}}": {"OutputUUID": u1, "Type": "ActionOutput", "OutputName": "URLs"},
                         f"{{{p2}, 1}}": {"Type": "ExtensionInput"},
                     }},
                 "WFSerializationType": "WFTextTokenString"}}},
    ],
}
with open(output, "wb") as f:
    plistlib.dump(shortcut, f, fmt=plistlib.FMT_BINARY)
