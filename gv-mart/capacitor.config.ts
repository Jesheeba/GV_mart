import type { CapacitorConfig } from "@capacitor/cli"

const config: CapacitorConfig = {
  appId: "com.gvmart.app",
  appName: "GV Mart",
  webDir: "dist",
  plugins: {
    SplashScreen: {
      launchShowDuration: 1500,
      backgroundColor: "#F4F1EC",
      androidSplashResourceName: "splash",
      showSpinner: false,
    },
    // OTA updates are driven entirely by our own code in src/lib/ota
    // (self-hosted manifest + signature verification), not the plugin's
    // built-in auto-update poller — so autoUpdate stays off and no
    // updateUrl is configured here.
    CapacitorUpdater: {
      autoUpdate: "off",
      appReadyTimeout: 10000,
      responseTimeout: 30,
      autoDeleteFailed: true,
      autoDeletePrevious: true,
    },
  },
}

export default config
