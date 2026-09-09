import Foundation

/// Herdr 0.9 palette data from src/app/state.rs. Token order follows Palette.
public enum EndpointThemeCatalog {
    public static let tokens = ["accent", "panel_bg", "sidebar_bg", "active_row_bg", "selection_bg", "surface0", "surface1", "surface_dim", "overlay0", "overlay1", "text", "subtext0", "mauve", "green", "yellow", "red", "blue", "teal", "peach"]
    public static let names = ["catppuccin", "catppuccin-latte", "terminal", "tokyo-night", "tokyo-night-day", "dracula", "nord", "gruvbox", "gruvbox-light", "one-dark", "one-light", "solarized", "solarized-light", "kanagawa", "kanagawa-lotus", "rose-pine", "rose-pine-dawn", "vesper"]
    static let values: [String: [String]] = [
        "catppuccin": ["#89b4fa", "#181825", "reset", "#1e1e2e", "#313244", "#313244", "#45475a", "#1e1e2e", "#6c7086", "#7f849c", "#cdd6f4", "#a6adc8", "#cba6f7", "#a6e3a1", "#f9e2af", "#f38ba8", "#89b4fa", "#94e2d5", "#fab387"],
        "catppuccin-latte": ["#1e66f5", "#eff1f5", "reset", "#e6e9ef", "#bdd0f5", "#ccd0da", "#bcc0cc", "#e6e9ef", "#9ca0b0", "#8c8fa1", "#4c4f69", "#6c6f85", "#8839ef", "#40a02b", "#df8e1d", "#d20f39", "#1e66f5", "#179299", "#fe640b"],
        "terminal": ["blue", "reset", "reset", "darkgray", "reset", "reset", "darkgray", "darkgray", "gray", "white", "reset", "gray", "gray", "green", "yellow", "lightred", "blue", "cyan", "yellow"],
        "tokyo-night": ["#7aa2f7", "#1a1b26", "reset", "#232636", "#2d3650", "#24283b", "#414868", "#1a1b26", "#565f89", "#697196", "#c0caf5", "#a9b1d6", "#bb9af7", "#9ece6a", "#e0af68", "#f7768e", "#7aa2f7", "#7dcfff", "#ff9e64"],
        "tokyo-night-day": ["#2e7de9", "#e1e2e7", "reset", "#d2d3da", "#b6cae7", "#c4c8da", "#a8aecb", "#d2d3da", "#8990b3", "#68709a", "#3760bf", "#6172b0", "#7847bd", "#587539", "#8c6c3e", "#f52a65", "#2e7de9", "#118c74", "#b15c00"],
        "dracula": ["#bd93f9", "#282a36", "reset", "#373c52", "#463f5d", "#44475a", "#6272a4", "#282a36", "#6272a4", "#828cb4", "#f8f8f2", "#d2d2dc", "#ff79c6", "#50fa7b", "#f1fa8c", "#ff5555", "#8be9fd", "#8be9fd", "#ffb86c"],
        "nord": ["#88c0d0", "#2e3440", "reset", "#434c5e", "#40505d", "#3b4252", "#434c5e", "#2e3440", "#4c566a", "#646e82", "#eceff4", "#d8dee9", "#b48ead", "#a3be8c", "#ebcb8b", "#bf616a", "#81a1c1", "#8fbcbb", "#d08770"],
        "gruvbox": ["#d79921", "#282828", "reset", "#323130", "#4b3f27", "#3c3836", "#504945", "#282828", "#928374", "#a89984", "#ebdbb2", "#d5c4a1", "#d3869b", "#b8bb26", "#fabd2f", "#fb4934", "#83a598", "#8ec07c", "#fe8019"],
        "gruvbox-light": ["#076678", "#fbf1c7", "reset", "#f2e5bc", "#ebdbb2", "#ebdbb2", "#d5c4a1", "#f2e5bc", "#928374", "#7c6f64", "#3c3836", "#504945", "#8f3f71", "#79740e", "#b57614", "#9d0006", "#076678", "#427b58", "#af3a03"],
        "one-dark": ["#61afef", "#282c34", "reset", "#313640", "#334659", "#2c313a", "#3e4451", "#282c34", "#5c6370", "#737a87", "#abb2bf", "#969ca8", "#c678dd", "#98c379", "#e5c07b", "#e06c75", "#61afef", "#56b6c2", "#d19a66"],
        "one-light": ["#4078f2", "#fafafa", "reset", "#d8dbe2", "#cddbf8", "#f0f0f1", "#e5e5e6", "#f5f5f6", "#a0a1a7", "#686b77", "#383a42", "#686b77", "#a626a4", "#50a14f", "#c18401", "#e45649", "#4078f2", "#0184bc", "#986801"],
        "solarized": ["#268bd2", "#002b36", "reset", "#164b57", "#083e55", "#073642", "#586e75", "#002b36", "#586e75", "#657b83", "#93a1a1", "#839496", "#d33682", "#859900", "#b58900", "#dc322f", "#268bd2", "#2aa198", "#cb4b16"],
        "solarized-light": ["#268bd2", "#fdf6e3", "reset", "#eee8d5", "#c9dcdf", "#eee8d5", "#93a1a1", "#eee8d5", "#93a1a1", "#586e75", "#657b83", "#839496", "#d33682", "#859900", "#b58900", "#dc322f", "#268bd2", "#2aa198", "#cb4b16"],
        "kanagawa": ["#7e9cd8", "#1f1f28", "reset", "#363646", "#32384b", "#2a2a37", "#363646", "#1f1f28", "#727169", "#87867d", "#dcd7ba", "#c8c3aa", "#957fb8", "#76946a", "#c0a36e", "#c34043", "#7e9cd8", "#7fb4ca", "#ffa066"],
        "kanagawa-lotus": ["#4d699b", "#f2ecbc", "reset", "#d5cea3", "#dcd5ac", "#dcd5ac", "#c9cbd1", "#d5cea3", "#a09cac", "#8a8980", "#545464", "#43436c", "#624c83", "#6f894e", "#77713f", "#c84053", "#4d699b", "#4e8ca2", "#cc6d00"],
        "rose-pine": ["#c4a7e7", "#191724", "reset", "#26233a", "#3b344b", "#1f1d2e", "#26233a", "#26233a", "#6e6a86", "#908caa", "#e0def4", "#c8c5dc", "#c4a7e7", "#31748f", "#f6c177", "#eb6f92", "#31748f", "#9ccfd8", "#ea9a97"],
        "rose-pine-dawn": ["#907aa9", "#faf4ed", "reset", "#e3d9cf", "#f2e9e1", "#f2e9e1", "#fffaf3", "#f2e9e1", "#9893a5", "#797593", "#464261", "#797593", "#907aa9", "#286983", "#ea9d34", "#b4637a", "#286983", "#56949f", "#d7827e"],
        "vesper": ["#ffc799", "#1a1a1a", "reset", "#101010", "#232323", "#232323", "#282828", "#101010", "#5c5c5c", "#7e7e7e", "#ffffff", "#a0a0a0", "#ffd1a8", "#99ffe4", "#ffc799", "#ff8080", "#b0b0b0", "#66ddcc", "#ffc799"],
    ]

    public static func canonicalName(_ value: String) -> String? {
        let name = value.lowercased().replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "_", with: "-")
        let aliases = ["catppuccin-mocha": "catppuccin", "latte": "catppuccin-latte", "light": "catppuccin-latte",
                       "tokyonight": "tokyo-night", "tokyo-day": "tokyo-night-day", "tokyonight-day": "tokyo-night-day",
                       "gruvbox-dark": "gruvbox", "onedark": "one-dark", "onelight": "one-light",
                       "solarized-dark": "solarized", "lotus": "kanagawa-lotus", "rosepine": "rose-pine",
                       "rosepine-dawn": "rose-pine-dawn", "dawn": "rose-pine-dawn"]
        let canonical = aliases[name] ?? name
        return values[canonical] == nil ? nil : canonical
    }

    static func sibling(_ name: String, dark: Bool) -> String {
        let pairs = [["catppuccin", "catppuccin-latte"], ["tokyo-night", "tokyo-night-day"],
                     ["gruvbox", "gruvbox-light"], ["one-dark", "one-light"], ["solarized", "solarized-light"],
                     ["kanagawa", "kanagawa-lotus"], ["rose-pine", "rose-pine-dawn"]]
        return pairs.first(where: { $0.contains(name) })?[dark ? 0 : 1] ?? name
    }
}
