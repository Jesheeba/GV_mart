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
  },
}

export default config
