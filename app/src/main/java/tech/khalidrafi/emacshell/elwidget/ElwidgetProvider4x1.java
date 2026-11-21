package tech.khalidrafi.emacshell.elwidget;

/**
 * Launcher entry for the 4x1 widget size.
 *
 * The manifest merger rejects the same receiver class declared more
 * than once, so each size is a thin subclass of {@link ElwidgetProvider}
 * with its own receiver element and provider XML; all behaviour stays
 * in the base class and is keyed by widget id, not by class.
 */
public class ElwidgetProvider4x1 extends ElwidgetProvider {
}
