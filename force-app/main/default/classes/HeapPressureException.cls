/**
 * Thrown by DocGenService.processXml when the sync path detects it's about to
 * exceed safe heap (~75% of limit). Carries the giant relationship name so the
 * controller can return a structured signal and the runner LWC can auto-fallback
 * to the giant-query batch path without user intervention.
 *
 * Not a subclass of DocGenException — callers need to distinguish heap pressure
 * (retry-able via giant path) from real generation errors (surface to user).
 */
public with sharing class HeapPressureException extends Exception {
    public String relationshipName;
}
