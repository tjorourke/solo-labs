# Setting up the vision demo suite on your laptop

This gets the whole suite running on your own machine: the kind clusters for the mesh and
agentic demos, the customer console on `localhost:8900`, and, if you want the
model-routing pages, an EKS cluster with two GPUs in your own AWS account.

[README.md](README.md) explains what each part demonstrates. This page covers setup.

## What you need

### A laptop with enough memory

Everything runs in kind, so memory is the limit. Give your container runtime at least
this much:

| You want to run | Clusters | Memory for the runtime |
|---|---|---|
| Parts 1-3 (ambient, L4, waypoint) | `mesh1` + `mesh2` | 16 GB |
| Parts 1-4, 7, 8, 11, 13 and the console | `mesh1` + `mesh2` with the Part 4 and Part 7 extras | 20 GB |
| Everything, including Parts 5/12 and 6 | adds `substrate` and `inference` | 24 GB or more |

You do not need every cluster up at once. `docker stop` a cluster's node containers
between demos and `docker start` them again: kind survives it.

### macOS: use OrbStack

The clusters get LoadBalancer addresses from MetalLB inside the kind Docker network, and
the console and the notebooks reach the UIs as `<name>.<address>.sslip.io`. OrbStack routes
from macOS to those container addresses. Docker Desktop does not, so every UI link times
out with nothing in any cluster log. Install [OrbStack](https://orbstack.dev) and make it
the active Docker context (`docker context use orbstack`).

On Linux, Docker Engine routes to the kind network already. Raise the inotify limits
before creating several kind clusters, or pods fail with `too many open files`:

```bash
sudo sysctl fs.inotify.max_user_instances=512 fs.inotify.max_user_watches=524288
```

### Tools

The prerequisites script checks every tool the labs use, and installs the missing ones
with Homebrew on macOS:

```bash
../scripts/install-prereqs.sh             # check
../scripts/install-prereqs.sh --install   # install what is missing
```

The suite needs `docker`, `kind`, `kubectl`, `helm`, `jq`, `curl`, `openssl`, `gcloud` and
`python3` with PyYAML (`python3 -m pip install pyyaml`). `setup.sh` downloads the matching
Solo `istioctl` itself. Then add the following:

- Notebooks: Jupyter with the Bash kernel.

  ```bash
  python3 -m pip install jupyterlab bash_kernel && python3 -m bash_kernel.install
  ```

- Part 4 and Part 8: `arctl`, the AgentRegistry CLI, at the version the suite was tested
  with.

  ```bash
  curl -sSL https://storage.googleapis.com/agentregistry-enterprise/install.sh | ARCTL_VERSION=v2026.8.0 sh
  ```

- Substrate Scope (optional, Part 5): Node 18 or later.
- The EKS cluster: the AWS CLI v2, `eksctl`, and OpenTofu (`tofu`) if you publish hostnames.

### Keys and logins

| What | Used by |
|---|---|
| `SOLO_ISTIO_LICENSE_KEY`, `AGENTGATEWAY_LICENSE_KEY` | everything on `mesh1`/`mesh2`, and the EKS cluster |
| `KAGENT_ENT_LICENSE_KEY` (or `SOLO_LICENSE_KEY`) | Part 4, Parts 5/12 |
| `ANTHROPIC_API_KEY` | Parts 5, 7, 11, 13 and the EKS frontier route. Calls are billed to this key |
| `GITHUB_PAT` with read access | Part 8 |
| `gcloud auth login` | `setup.sh` pulls the Solo Istio images with it |
| An AWS account | only the AgentCore steps of Part 4 and the EKS cluster |

## Get the code

Clone all of solo-labs, not just this folder. The suite reads labs that sit next to it,
for example `../agentgateway-inference-routing-kind` for Part 6 and the two EKS labs for
the GPU cluster.

```bash
git clone https://github.com/tjorourke/solo-labs.git
cd solo-labs/vision-demo-2026
cp secrets.env.example secrets.env     # then fill in the keys
```

Every script reads `./secrets.env` by default. To keep your keys somewhere else, export
`SECRETS_FILE=/path/to/file` instead.

## Bring up the kind clusters

Run each line from the `vision-demo-2026` folder. Each script skips whatever is already
there, so re-running one after a failure is safe.

| Step | Command | Gives you | Time |
|---|---|---|---|
| 1 | `./demo-scripts/setup.sh` | `mesh1` + `mesh2`: Solo Istio ambient, agentgateway, Gloo UI, Keycloak. Parts 1-3 | 15-20 min |
| 2 | `./demo-scripts/agentregistry/setup-mesh1.sh` | kagent, AgentRegistry and the Enterprise UI on `mesh1`. Parts 4 and 8 | ~8 min |
| 3 | `./demo-scripts/llm-gateway.sh` | the AI gateway, local model servers and the MCP server on `mesh1`. Part 7 | ~1 min |
| 4 | `./demo-scripts/substrate-cluster.sh` | the `substrate` cluster with kagent 0.5.6 and gVisor. Parts 5 and 12 | |
| 5 | `(cd ../agentgateway-inference-routing-kind && ./scripts/quick.sh up)` | the `inference` cluster. Part 6 | |

Or run all of them in one go, skipping what you do not need:

```bash
SKIP_SUBSTRATE=true SKIP_INFERENCE=true ./demo-scripts/setup-all-labs.sh
```

For the AgentCore steps in Part 4, copy `demo-scripts/agentregistry/.env.aws.example` to
`.env.aws` and fill in your AWS profile, account ID and a git repo you can push to. The
rest of Part 4 runs without it.

## Run a demo

There are three ways to drive the same steps:

- **The console.** One page per demo, one step at a time, with a Run button and a terminal:

  ```bash
  cd demo-console
  cp console.env.example console.env
  ./run.sh                  # http://localhost:8900
  ```

- **The notebooks.** Start `jupyter lab`, open a `demo-N-*.ipynb` with the Bash kernel and
  run its Connect cell first.
- **A terminal.** `source demo-scripts/env.sh N` loads that demo's variables, then paste
  the commands from the notebook.

## The EKS GPU cluster

The console's model-routing pages (Gateway decisions, Cost, My agents and the
Agentdesktop flow) run on a real EKS cluster: two open-weight models on two GPUs, the
Enterprise agentgateway, vLLM Semantic Router and OPA choosing the model for each prompt,
and one frontier route to Anthropic. Nothing else in the suite needs it.

You can build one yourself, or use one a colleague has shared with you.

### Build your own

The cluster is two labs run in order: [Part 1](../agentgateway-inference-model-routing-eks/)
provides the EKS cluster definition and the GPU scaler, and
[Part 4](../agentgateway-inference-task-routing-eks/) installs the platform, the models and
the routing. `demo-scripts/eks.sh` drives both from one settings file.

**Cost.** Two `g7e.2xlarge` cost about $11.70/hr together while the GPUs are up. The
control plane, two CPU nodes and the volumes cost a few dollars a day more. Scale the GPUs
to zero at the end of every day. The model weights stay on their volumes, so bringing them
back takes minutes rather than a 76 GB download.

**Capacity.** Check you have the quota for two `g7e.2xlarge` in the region. GPU capacity
in a single zone moves hour to hour, so before a customer session, hold the nodes with an
On-Demand Capacity Reservation in your GPU zone. Always set an end date: a reservation
bills the full rate whether or not anything is running in it.

```bash
aws ec2 create-capacity-reservation --instance-type g7e.2xlarge \
  --instance-platform Linux/UNIX --availability-zone <your GPU_AZ> --instance-count 2 \
  --instance-match-criteria open --end-date-type limited --end-date <when you finish>
```

**Settings.** Copy the template and fill it in:

```bash
cp eks.env.example eks.env
```

`AWS_PROFILE` and `EXPECTED_AWS_ACCOUNT` are required. `eks.sh` refuses to create
anything when the profile's session is in a different account, so a profile left
exported in your shell for other work cannot be used by mistake.

**Build it.**

```bash
./demo-scripts/eks.sh check       # profile, account, region, keys, and whether the cluster exists
./demo-scripts/eks.sh render      # the eksctl cluster definition it will create
./demo-scripts/eks.sh up          # cluster ~20 min, then the platform and both models
./demo-scripts/eks.sh test        # the routing flow and the controls
```

`up` also writes the cluster's kubectl context into `demo-console/console.env`, so the
console's Gateway decisions page attaches to it on the next `./run.sh`.

**Hostnames (optional).** Cursor, Claude Desktop and the console's Agentdesktop and My
agents pages need the gateway on a real hostname with a certificate a browser trusts. Set
`ZONE` in `eks.env` to a publicly delegated Route53 zone you own, then:

```bash
./demo-scripts/eks.sh endpoints   # ACM certificates, load balancers, agw.<zone> and soloui.<zone>
./demo-scripts/eks.sh console-env # put the hostnames in demo-console/console.env
```

The UI hostname only accepts your current IP address. After your address changes, run
`./demo-scripts/eks.sh endpoints refresh-ip`.

**Every evening.**

```bash
./demo-scripts/eks.sh gpu down    # scale the GPU nodegroup to zero
./demo-scripts/eks.sh gpu status  # read it back: desired 0
kubectl --context "$(./demo-scripts/eks.sh context)" get nodes -l role=gpu   # no nodes
```

`gpu up` brings them back and waits until both nodes advertise a GPU.

**When you are finished with it.**

```bash
./demo-scripts/eks.sh teardown    # hostnames, load balancers, then the cluster
../scripts/aws-sweep.sh           # read-only check for anything the delete left behind
```

The teardown waits for AWS to confirm the load balancers are gone before it deletes the
cluster, because a load balancer left attached to a subnet stops the VPC deleting. Do not
trust its exit code: `aws-sweep.sh` lists classic ELBs, unattached volumes, NAT gateways
and failed stacks that a cluster delete cannot see.

### Use a shared cluster

If someone already has a cluster running, they can give you access to it without giving
you anything in their AWS account. You get a small bundle, sent privately, with a
`README.txt` that walks through it:

- `model-routing.kubeconfig`: the cluster endpoint and a token that is yours alone
- `console.env`: the context name and the gateway hostnames for the console
- `signing-key.pem`: the demo identity key, used by the My agents page to sign tokens

You do not need an AWS login. You cannot start or stop the GPUs with this access, so if
the models are not answering, ask whoever shared the cluster whether the GPUs are up.
Other people use the same cluster, so leave its namespaces, models and gateway alone.

## Between demos

```bash
./demo-scripts/reset.sh       # remove every demo workload, keep the platform
./demo-scripts/wake.sh        # after the laptop has slept: renews expired mesh certificates
./demo-scripts/setup.sh teardown   # delete mesh1 and mesh2
```

Each notebook and each console lab also has its own reset, which undoes just that demo.

## When something does not work

| What you see | Usually |
|---|---|
| Every UI link times out on macOS | Docker Desktop is the active context. Use OrbStack |
| `gcloud not authenticated` from `setup.sh` | run `gcloud auth login` |
| Pods stuck `Pending` on a kind cluster | not enough memory for the runtime. Stop the clusters you are not using |
| mTLS or certificate errors after a sleep | `./demo-scripts/wake.sh` |
| Gateway decisions says "not attached" | `MODEL_ROUTING_CONTEXT` in `demo-console/console.env` does not match a context in your kubeconfig |
| The EKS models time out | the GPUs are down: `./demo-scripts/eks.sh gpu status` |
| `profile ... is in account ..., eks.env expects ...` | the AWS session is in a different account. Fix `AWS_PROFILE` in `eks.env` and run `aws sso login --profile <it>` |
