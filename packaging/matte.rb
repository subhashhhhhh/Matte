# Template for Casks/matte.rb in subhashhhhhh/homebrew-matte. scripts/release.sh
# fills in version and sha256 in the tap's copy on each release.
cask "matte" do
  arch arm: "AppleSilicon", intel: "Intel"

  version "1.0"
  sha256 arm:   "0000000000000000000000000000000000000000000000000000000000000000",
         intel: "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/subhashhhhhh/Matte/releases/download/v#{version}/Matte-#{version}-#{arch}.dmg"
  name "Matte"
  desc "Native, low-memory Instagram client"
  homepage "https://matte.subhashh.tech"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :sequoia

  app "Matte.app"

  # Matte isn't notarized; clearing the flag spares Homebrew users the Gatekeeper prompt.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Matte.app"]
  end

  uninstall quit: "com.subhash.Matte"

  zap trash: [
    "~/Library/Application Support/com.subhash.Matte",
    "~/Library/Caches/com.subhash.Matte",
    "~/Library/Caches/MatteUpdate",
    "~/Library/HTTPStorages/com.subhash.Matte",
    "~/Library/Preferences/com.subhash.Matte.plist",
    "~/Library/Saved Application State/com.subhash.Matte.savedState",
    "~/Library/WebKit/com.subhash.Matte",
  ]
end
