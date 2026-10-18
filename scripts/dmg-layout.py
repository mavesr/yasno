"""Write Finder's layout on the mounted image; this does not automate Finder."""
import sys
import unicodedata
from pathlib import Path

from ds_store import DSStore
from mac_alias import Alias

volume = Path(sys.argv[1])
background = Alias.for_file(str(volume / ".background" / "background.png")).to_bytes()
with DSStore.open(str(volume / ".DS_Store"), "w+") as store:
    store["."]["bwsp"] = {
        "ShowStatusBar": False,
        "ShowPathbar": False,
        "ShowToolbar": False,
        "ShowSidebar": False,
        "ContainerShowSidebar": False,
        "ShowTabView": False,
        "PreviewPaneVisibility": False,
        "SidebarWidth": 0,
        "WindowBounds": "{{200, 140}, {660, 520}}",
    }
    store["."]["icvp"] = {
        "viewOptionsVersion": 1,
        "backgroundType": 2,
        "backgroundColorRed": 0.96,
        "backgroundColorGreen": 0.97,
        "backgroundColorBlue": 0.95,
        "backgroundImageAlias": background,
        "iconSize": 80.0,
        "textSize": 14.0,
        "gridSpacing": 100.0,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
        "arrangeBy": "none",
        "labelOnBottom": True,
        "showIconPreview": False,
        "showItemInfo": False,
    }
    store["."]["vSrn"] = ("long", 1)
    store["."]["icvl"] = ("type", b"icnv")
    store["Ясно.app"]["Iloc"] = (190, 218)
    store["Программы"]["Iloc"] = (470, 218)
    store[unicodedata.normalize("NFD", "Первый запуск.txt")]["Iloc"] = (330, 320)
