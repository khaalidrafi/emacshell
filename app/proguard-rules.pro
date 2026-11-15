# Vendored from termux-app v0.118.3 plus keeps for emacshell glue.
# Release builds currently run with minifyEnabled false; these rules are
# here for when that changes (see REVIEW.org).

# Termux keeps (upstream proguard-rules.pro)
-dontwarn android.util.MutablePair
-keep class androidx.appcompat.app.ActionBar {
    public <init>();
}
-keep class com.termux.shared.termux.TermuxConstants {
    *;
}
-keep class com.termux.shared.termux.TermuxConstants$* {
    *;
}

# Emacshell glue is entered from AndroidManifest.xml and from the
# activity lifecycle callbacks; never strip or rename it.
-keep class tech.khalidrafi.emacshell.** { *; }
