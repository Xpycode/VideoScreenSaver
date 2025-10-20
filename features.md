# Proposed Features for Video Screen Saver

Here is a list of potential new features, categorized from highest-impact to smaller refinements.

### High-Impact Features

1.  **Multiple Source Folders:**
    *   **What:** Allow the user to add and remove multiple folders to source videos from, instead of being limited to a single folder.
    *   **Why:** Users often have videos scattered across different directories (`~/Movies`, `~/Downloads`, a folder on an external drive, etc.). This would make the screensaver much more versatile.
    *   **How:** The UI would change from a single "Choose Folder" button to a list view with `+` and `-` buttons to manage a list of source folders.

2.  **Video Scaling Options:**
    *   **What:** Add a setting to control how videos are scaled to fit the screen.
    *   **Why:** The current "Fill Screen" (`ResizeAspectFill`) behavior is great for covering the whole screen, but it can crop the top/bottom or sides of a video. Giving users a choice is a major improvement.
    *   **How:** A new pop-up menu in the settings sheet with options like:
        *   **Fill Screen (Default):** The current behavior.
        *   **Fit to Screen:** Shows the entire video, adding black bars if necessary (letterboxing).
        *   **Center:** Displays the video at its actual size in the center of the screen.

### Advanced Features

3.  **Recursive Folder Scanning:**
    *   **What:** Add a "Search Subfolders" checkbox.
    *   **Why:** If a user selects a main video folder, they might have videos organized into subfolders. This option would allow the screensaver to find and play those videos automatically.

### Polishing & User Experience

5.  **Volume Control:**
    *   **What:** Instead of just an "Enable Audio" checkbox, replace it with a volume slider.
    *   **Why:** This gives the user more granular control, allowing for quiet background audio instead of an all-or-nothing choice.

6.  **More Transition Options:**
    *   **What:** Add more advanced transitions like "Slide In" or "Ken Burns effect" (slow zoom and pan).
    *   **Why:** Provides more visual variety and a more premium feel.
    *   **How:** This would involve more complex Core Animation work.
