import NetworkExtension

autoreleasepool {
    NEProvider.startSystemExtensionMode()
}

// Never returns: the system extension lives until the system stops it.
dispatchMain()
