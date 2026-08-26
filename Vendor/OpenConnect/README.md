# Embedded OpenConnect runtime

Place an audited universal `libopenconnect` build in this directory before
building the Xcode project:

```text
Vendor/OpenConnect/
├── include/openconnect.h
└── lib/libopenconnect.dylib
```

The production build must embed the library and every non-system dependency
(for example GnuTLS) in the system extension, rewrite load commands to use
`@rpath`, sign nested binaries first, and include LGPL-2.1 notices plus the
corresponding source offer. Do not copy the Homebrew library into a release:
its absolute dependency paths are development-only.

The pinned source version, checksum and license materials belong in a release
manifest before external distribution.

