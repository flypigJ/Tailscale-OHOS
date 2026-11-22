/** Offline setup instructions; never applies policy or runs commands. */
export interface FeatureGuideSection {
  id: string;
  title: Resource;
  body: Resource;
  policy: string;
  commands: string;
  reference: string;
}

export const TAILDRIVE_READ_ONLY_POLICY: string = `{
  "nodeAttrs": [
    {
      "target": [
        "you@example.com"
      ],
      "attr": [
        "drive:share",
        "drive:access"
      ]
    }
  ],
  "grants": [
    {
      "src": [
        "you@example.com"
      ],
      "dst": [
        "autogroup:self"
      ],
      "app": {
        "tailscale.com/cap/drive": [
          {
            "shares": [
              "docs"
            ],
            "access": "ro"
          }
        ]
      }
    }
  ]
}`;

export const FEATURE_GUIDE_SECTIONS: FeatureGuideSection[] = [
  {
    id: 'connect',
    title: $r('app.string.feature_guide_connect_title'),
    body: $r('app.string.feature_guide_connect_body'),
    policy: '',
    commands: "",
    reference: "https://login.tailscale.com/admin/machines"
  },
  {
    id: 'taildrop',
    title: $r('app.string.feature_guide_taildrop_title'),
    body: $r('app.string.feature_guide_taildrop_body'),
    policy: '',
    commands: "",
    reference: "https://tailscale.com/kb/1106/taildrop"
  },
  {
    id: 'taildrive',
    title: $r('app.string.feature_guide_taildrive_title'),
    body: $r('app.string.feature_guide_taildrive_body'),
    policy: TAILDRIVE_READ_ONLY_POLICY,
    commands: "Windows (PowerShell):\ntailscale drive share docs \"C:\\Users\\YourName\\Documents\\Shared\"\n\nmacOS / Linux:\ntailscale drive share docs \"$HOME/Shared\"\n\nCheck published shares:\ntailscale drive list",
    reference: "https://tailscale.com/kb/1369/taildrive\nhttps://tailscale.com/kb/1550/visual-editor"
  },
  {
    id: 'localsend',
    title: $r('app.string.feature_guide_localsend_title'),
    body: $r('app.string.feature_guide_localsend_body'),
    policy: '',
    commands: "",
    reference: "https://localsend.org"
  },
  {
    id: 'exit',
    title: $r('app.string.feature_guide_exit_title'),
    body: $r('app.string.feature_guide_exit_body'),
    policy: '',
    commands: "sudo tailscale set --advertise-exit-node",
    reference: "https://tailscale.com/kb/1103/exit-nodes"
  },
  {
    id: 'subnet',
    title: $r('app.string.feature_guide_subnet_title'),
    body: $r('app.string.feature_guide_subnet_body'),
    policy: '',
    commands: "sudo tailscale set --advertise-routes=192.168.1.0/24",
    reference: "https://tailscale.com/kb/1019/subnets"
  },
  {
    id: 'media',
    title: $r('app.string.feature_guide_media_title'),
    body: $r('app.string.feature_guide_media_body'),
    policy: '',
    commands: "",
    reference: ""
  },
  {
    id: 'streaming',
    title: $r('app.string.feature_guide_streaming_title'),
    body: $r('app.string.feature_guide_streaming_body'),
    policy: '',
    commands: "",
    reference: ""
  },
  {
    id: 'security',
    title: $r('app.string.feature_guide_security_title'),
    body: $r('app.string.feature_guide_security_body'),
    policy: '',
    commands: "",
    reference: ""
  },
  {
    id: 'appearance',
    title: $r('app.string.feature_guide_appearance_title'),
    body: $r('app.string.feature_guide_appearance_body'),
    policy: '',
    commands: "",
    reference: ""
  }
];
