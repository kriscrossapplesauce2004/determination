package com.determination.companion;

/** Trusted-app facade over the native Determination control protocol. */
interface IDeterminationControl {
    String getStatusJson();
    String getCapabilitiesJson();
    int requestMode(String target);
}
