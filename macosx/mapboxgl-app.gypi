{
  'includes': [
    '../gyp/common.gypi',
  ],
  'targets': [
    { 'target_name': 'osxapp',
      'product_name': 'Mapbox GL',
      'type': 'executable',
      'product_extension': 'app',
      'mac_bundle': 1,
      'mac_bundle_resources': [
        'Credits.rtf',
        'Icon.icns',
        'Info.plist',
        'MainMenu.xib',
      ],

      'dependencies': [
        'mbgl.gyp:core',
        'mbgl.gyp:platform-<(platform_lib)',
        'mbgl.gyp:http-<(http_lib)',
        'mbgl.gyp:asset-<(asset_lib)',
        'mbgl.gyp:cache-<(cache_lib)',
      ],

      'sources': [
        './AppDelegate.h',
        './AppDelegate.m',
        './main.m',
      ],

      'xcode_settings': {
        'SDKROOT': 'macosx',
        'SUPPORTED_PLATFORMS':'macosx',
        'OTHER_LDFLAGS': [ '-stdlib=libc++', '-lstdc++' ],
        'INFOPLIST_FILE': '../macosx/Info.plist',
        'CLANG_ENABLE_OBJC_ARC': 'YES',
        'USER_HEADER_SEARCH_PATHS': '../include/mbgl/osx',
      },
    }
  ]
}
