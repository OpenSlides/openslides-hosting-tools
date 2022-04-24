# OpenSlides Hosting Tools

This repository contains various tools for managing
[OpenSlides 4](https://github.com/OpenSlides/OpenSlides/) instances, with
a focus on multi-instance deployments.  If you intend to only use a single
OpenSlides instance, you may want to try the simpler [regular
instructions](https://github.com/OpenSlides/OpenSlides/blob/main/README.md#setup-openslides)
first.

## Installation and Setup

While the regular OpenSlides setup requires only Docker Compose, the tools
provided here expect a setup consisting of Docker Swarm, HAProxy, and an
external database server.  For this reason, there are additional configuration
steps involved.

Even before installation, running `./osinstancectl.sh setup` can assist you in
determining if your system meets the basic prerequisites.  The command is safe
to run and won't make changes without additional prompts.

Run `make install` to install the included programs.  `osinstancectl.sh` will
be installed as `os4instancectl`; see the Makefile for details.

### Database setup

Not covered by the `setup` command is the fact that you must provide databases
for your instances.  This OpenSlides setup does not use the Postgres Docker
service that is part of OpenSlides' default Docker Compose setup.  You should
configure your database server in the configuration template file (usually at
`/etc/osinstancectl.d/config.yml.template`).  For the database configuration of
individual instances, see [Usage] below.

### HAProxy Setup

Instances created by `osinstancectl` are not meant to be exposed to the
internet directly.  All TLS features provided by the OpenSlides Docker Compose
setup will be disabled by default.  Instead, client connections to the
instances must be handled by a reverse proxy.

`osinstancectl` is hard-coded to add and delete routing rules in HAProxy's
configuration file.  For `osinstancectl` to edit the configuration file,
`haproxy.cfg` must contain markers that define the section which
`osinstancectl` should be managing for its rules.  See the included
`doc/haproxy.cfg.example` file for details.

## Configuration

### Configuration File

`osinstancectl`'s default settings can be changed using the file
`/etc/osinstancectl.d/os4instancectlrc`.  See the included
`doc/os4instancectlrc.example` file for details.

### Custom Instance Configuration Templates

For creating instances, the OpenSlides management tool uses two templates:
a configuration template (`config.yml`) and a Docker Compose template.

In the former, you must configure your database host.  Customizations of the
latter are optional.

### Hooks

Hooks are Bash scripts that get executed before, during, or after
`osinstancectl` actions.  They can be used for, e.g., automatically creating
databases or running cleaning up tasks.  The `doc/hooks/` directory contains
a few example hooks.

The hooks must be executable Bash scripts in a directory configured as
`HOOKS_DIR` in the configuration file.

## Usage

To get started, try adding an instance after consulting `os4instancectl help
add`.

After having created the instance and before starting it, its database must be
made available.  The instance's database configuration can be found in its
`config.yml` file; its suggested database password can be found in
`secrets/postgres_password`.  Once you have created a database with suitable
access permissions, you can start the instance.

Example:

```bash
# Build the 'openslides' tool in the correct version
openslides-bin-installer --build-revision=4.0.0-beta-20220330-17bbbc9
# Create an instance but choose to not start it yet.
os4instancectl --tag=4.0.0-beta-20220330-17bbbc9 --management-tool=latest \
  --local-only add openslides.example.com
# List the available instances
os4instancectl ls
# Next, create the instance's database; then:
os4instancectl start openslides.example.com
```

The available OpenSlides image versions for `--tag` can be found on OpenSlides'
[GitHub packages](https://github.com/orgs/OpenSlides/packages) page.  Please
note that there is no `latest` tag.
