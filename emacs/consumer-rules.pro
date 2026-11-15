# Keep the entire GNU Emacs Java layer.  The app module does not enable
# minification for now (see REVIEW.org); these rules exist so that a
# future minified build cannot silently strip entry points that Android
# or the Emacs C runtime reaches reflectively.
-keep class org.gnu.emacs.** { *; }
