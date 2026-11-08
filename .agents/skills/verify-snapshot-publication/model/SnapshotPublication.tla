--------------------- MODULE SnapshotPublication ---------------------
EXTENDS TLC

CONSTANTS Writers, SharedProcess, DigestFirst

VARIABLES phase, lockOwner, sidecar, manifest
vars == <<phase, lockOwner, sidecar, manifest>>

NoValue == "none"
Process(writer) == IF SharedProcess THEN "shared" ELSE writer

Init ==
  /\ phase = [writer \in Writers |-> "open"]
  /\ lockOwner = NoValue
  /\ sidecar = NoValue
  /\ manifest = NoValue

OpenLock ==
  \E writer \in Writers:
    /\ phase[writer] = "open"
    /\ phase' = [phase EXCEPT ![writer] = "lock"]
    /\ UNCHANGED <<lockOwner, sidecar, manifest>>

AcquireLock ==
  \E writer \in Writers:
    /\ phase[writer] = "lock"
    /\ IF lockOwner = NoValue \/ lockOwner = Process(writer)
         THEN /\ lockOwner' = Process(writer)
              /\ phase' = [phase EXCEPT ![writer] = "check"]
         ELSE /\ UNCHANGED lockOwner
              /\ phase' = [phase EXCEPT ![writer] = "close"]
    /\ UNCHANGED <<sidecar, manifest>>

CheckName ==
  \E writer \in Writers:
    /\ phase[writer] = "check"
    /\ phase' = [phase EXCEPT ![writer] =
         IF manifest = NoValue THEN "work" ELSE "close"]
    /\ UNCHANGED <<lockOwner, sidecar, manifest>>

FinishScan ==
  \E writer \in Writers:
    /\ phase[writer] = "work"
    /\ phase' = [phase EXCEPT ![writer] =
         IF DigestFirst THEN "digest" ELSE "manifest"]
    /\ UNCHANGED <<lockOwner, sidecar, manifest>>

InstallDigest ==
  \E writer \in Writers:
    /\ phase[writer] = "digest"
    /\ sidecar' = writer
    /\ phase' = [phase EXCEPT ![writer] =
         IF DigestFirst THEN "manifest" ELSE "close"]
    /\ UNCHANGED <<lockOwner, manifest>>

LinkManifest ==
  \E writer \in Writers:
    /\ phase[writer] = "manifest"
    /\ IF manifest = NoValue
         THEN /\ manifest' = writer
              /\ phase' = [phase EXCEPT ![writer] =
                   IF DigestFirst THEN "close" ELSE "digest"]
         ELSE /\ UNCHANGED manifest
              /\ phase' = [phase EXCEPT ![writer] = "close"]
    /\ UNCHANGED <<lockOwner, sidecar>>

AbortCall ==
  \E writer \in Writers:
    /\ phase[writer] \in {"lock", "check", "work", "digest", "manifest"}
    /\ phase' = [phase EXCEPT ![writer] = "close"]
    /\ UNCHANGED <<lockOwner, sidecar, manifest>>

CloseLock ==
  \E writer \in Writers:
    /\ phase[writer] = "close"
    /\ lockOwner' = IF lockOwner = Process(writer) THEN NoValue ELSE lockOwner
    /\ phase' = [phase EXCEPT ![writer] = "done"]
    /\ UNCHANGED <<sidecar, manifest>>

CrashProcess ==
  \E writer \in Writers:
    /\ phase[writer] \notin {"done", "crashed"}
    /\ phase' = [other \in Writers |->
         IF Process(other) = Process(writer) /\ phase[other] # "done"
           THEN "crashed"
           ELSE phase[other]]
    /\ lockOwner' = IF lockOwner = Process(writer) THEN NoValue ELSE lockOwner
    /\ UNCHANGED <<sidecar, manifest>>

Next == OpenLock \/ AcquireLock \/ CheckName \/ FinishScan \/ InstallDigest
        \/ LinkManifest \/ AbortCall \/ CloseLock \/ CrashProcess

Spec == Init /\ [][Next]_vars

VisibleManifestMatchesSidecar == manifest = NoValue \/ manifest = sidecar
=============================================================================
