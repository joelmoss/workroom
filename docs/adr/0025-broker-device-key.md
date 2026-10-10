# The Mac authenticates to the broker with a non-exportable device key, not a bearer token

Each Mac signs every broker request with a P-256 key, as a DPoP-shaped ES256 proof, so no token or exportable key lets another process running as the user act as this Mac. The key lives in the Secure Enclave where there is one, with its blob in the Keychain tied to the code signature; Intel Macs get a software key. Device keys are registered at the broker, so changing the scheme re-enrols every Mac.

Source: [`macapp/WorkroomApp/Core/Broker/BrokerDeviceKey.swift`](../../macapp/WorkroomApp/Core/Broker/BrokerDeviceKey.swift), [`BrokerClient.swift`](../../macapp/WorkroomApp/Core/Broker/BrokerClient.swift), [`docs/designs/oq20-remote-git-credentials.md`](../designs/oq20-remote-git-credentials.md).
