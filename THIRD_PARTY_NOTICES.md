# Third-party notices

CiscoConnect packages the OpenConnect executable and its dynamically linked
libraries. OpenConnect is licensed under LGPL-2.1; its corresponding source is
available from <https://www.infradead.org/openconnect/>. The distribution also
includes `vpnc-script`, licensed under GPL-2.0-or-later, with source available
from <https://gitlab.com/openconnect/vpnc-scripts>.

Each release must preserve the exact license texts and notices from its pinned
OpenConnect/Homebrew dependency set. `Scripts/prepare_openconnect_runtime.sh`
copies the OpenConnect LGPL text into the app. Before publishing a release,
review licenses for every embedded dylib and add their notices here.
