# Rai mixed views

Rai will compose panes from several Herdr endpoints in one presentation.

Herdr keeps ownership of machines, sessions, workspaces, tabs, panes, agents, and processes. Rai keeps a local composition that places references to those resources.

The source hierarchy remains:

```text
machine → session → workspace → tab → pane
```

The Rai presentation hierarchy is:

```text
Rai composition
└── Rai space
    └── Rai tab
        └── Rai pane slot
```

Every pane slot stores an endpoint-qualified workspace, tab, and pane reference. Endpoint identity uses the machine profile and session. Labels do not identify resources.

A Rai tab may contain pane slots from any registered Rai space. This permits one tab to show panes from different machines, sessions, and Herdr workspaces. A source may appear in more than one Rai tab, but one tab cannot contain the same source twice.

Rai persists local IDs and source references. Connection IDs and Herdr boot IDs are runtime values. Rai clears them when it loads a composition. A pane slot accepts input only when its current connection and boot identity match its attachment.

The first vertical slice adds the shared model, validation, atomic persistence, endpoint projection, and an app view model. It does not move Herdr processes or change the existing default session.

## Agent interface

Agents keep using Herdr. They do not need a Rai CLI to manage terminal resources.

Herdr remains the source of truth for process state, pane input, focus, layout, agent status, and lifecycle. Rai mirrors that state through its endpoint connections.

Rai-only operations stay local. These operations include adding a source to a view, changing slot order, changing labels, and saving a composition.

When an agent or user changes a source resource, Rai sends the action to Herdr. The request includes the owning endpoint and the current server boot identity. Rai rejects the request after a reconnect or server replacement.

An optional Rai API can expose saved view operations later. That API must edit presentation state only. It must not become a second command path for Herdr resources.

The current UI slice opens a Rai View sheet from the primary window. It lists connected Herdr workspaces, saves selected spaces, and opens their panes in a mixed tab.

The UI can add a workspace as Rai tabs or add its panes to the selected Rai tab. It uses one endpoint connection and terminal pool per machine session.

The UI renders a two-column first layout. Later work can add saved pane
geometry without changing source ownership.

The current follow-up adds a local Rai tab button and drag reorder for pane
slots. Rai saves both changes in the existing composition file. The reorder
changes only the Rai slot order. It never changes Herdr tab or pane ownership.

The UI must keep these rules:

- A source action uses the source endpoint and current boot identity.
- A stale connection or boot identity rejects the action.
- A disconnected source remains visible as a stale slot.
- A Rai layout change does not change Herdr focus unless the user selects a source action.
- The default Herdr session remains the existing source for the current window.

The model limits persisted data to 64 spaces, 128 tabs, 512 pane slots, and one megabyte of encoded data.
