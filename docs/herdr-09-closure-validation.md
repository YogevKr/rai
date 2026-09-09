# Workspace closure review

Review found a legacy closure path that opened a new socket after snapshot validation.
The legacy host now retains one closure endpoint for each resource generation.
It publishes that endpoint after the matching session refresh.
Generation changes disconnect the endpoint. Closure never reconnects a mutation.
The closure loop checks reviewed worktree identity and group membership before each write.
Errors report confirmed progress and warn that the last request can have completed.
Endpoint-less servers reject this closure path and require an endpoint-capable Herdr release.

A transport regression covers success, server replacement, and group membership changes.
All cases use isolated Unix sockets. No case starts Herdr or controls the user's session.
Log: `/tmp/rai-workspace-close-transport.log`.
Native endpoint closure already used its captured boot and existing socket.


## Real Herdr correction

Closure now activates the retained endpoint before writing and deactivates it afterward.
The fake server requires activation before accepting closure.
The endpoint workspace adapter now handles the actual Herdr 0.9 record shape.
Endpoint worktree records provide group keys and linked-worktree flags, without checkout paths.
The closure check uses those shared identity fields.
Legacy phone closure now requires the connection identity captured during confirmation.
Missing and stale identities fail before a closure request.

Twenty-six focused tests passed, including the real Herdr 0.9 closure test.
The real fixture closed two single workspaces, then a primary and linked worktree group.
The group test preserved the unrelated workspace `w3`.
The test checks reviewed IDs because Herdr creates a fallback workspace after closing the last workspace.
The fixture used `/private/tmp/rai-close-real-coh9fwxi` and its `.rai-closure-owned` marker.
The fixture used its own configuration, sockets, shell configuration, state, and cache.
The fixture server stopped after verification. The commands22 fixture was not changed.

Test log: `/tmp/rai-plugin-close-activation-tests.log`.
Remaining-workspace evidence: `/private/tmp/rai-close-real-coh9fwxi/after-close.json`.
Stop evidence: `/private/tmp/rai-close-real-coh9fwxi/stop.log`.
