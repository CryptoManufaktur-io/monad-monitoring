# Monad Monitoring

The purpose of this repo is to assist validators/inidividuals to monitor their own Monad node installation.  

In order to use this repo/guide you need to already have a Monad node running. Also docker must be installed as this monitoring stack makes use of docker.

Currently, the Monad validator sends data to the Monad team using OpenTelemetry, and this process should continue. However, there is no metrics endpoint available from the Monad validator node at this time. This monitoring repository enables you to intercept the OpenTelemetry data, create a metrics endpoint, and still forward the same information to the Monad team. The repository runs its own OpenTelemetry, receives metrics from your Monad node, generates a metrics endpoint, and forwards the data to the Monad team, while also providing a Grafana dashboard for monitoring.

You do not need to use the OpenTelemetry provided with Monad install if using this as it is bundled with the same components. 

## Install 

To make use of this repository and get monitoring running follow the below steps

Clone the repository
```
git clone https://github.com/staking4all/monad-monitoring.git
```

Check .env variables for Grafana, change as needed
```
cd monad-monitoring
nano .env
```

Add your validator secp key to the collector yaml at `collector/otel-collector-config.yaml`. You will see in `collector/otel-collector-config.yaml` the value `value: "SECP_KEY"`, this should be changed to your SECP Key, example would be `value: "036bbd589054dacff9febaa948f88f2d057537efcfea3624c2405873ed380548d3"`
```
nano collector/otel-collector-config.yaml
```

To run a Monad node you can either use a binary or docker. To cater for both types of Monad installations we have provided two docker files. `docker-compose-binary.yaml` for a binary based installtion, `docker-compose-docker.yaml` for a docker based installation. Start up the monitoring stack with the relevant file.

For a binary installation use
```
docker compose -f docker-compose-binary.yaml up -d

```

For a docker installation use
```
docker compose -f docker-compose-docker.yaml up -d

```

Four containers should start that includes
- OpenTelemetry
- Prometheus
- Grafana
- Node exporter

For docker based Monad installations you must edit Monad Validator nodes `docker-compose.yml` to forward OpenTelemetry traffic to your installation. We assume the Monad validator installation is in your home directory. Within docker-compose.yml replace `--otel-endpoint http://peach10.devcore4.com:4317`  with your local otel `--otel-endpoint http://monad-monitoring-otel-collector-1:4317`. 
```
cd /home/monad/
nano docker-compose.yml
```

Restart your Monad validator if using docker based version
```
cd /home/monad/
docker compose down
docker compose up -d
```

If everything is working correctly you should be able to retrieve metrics on `http://localhost:8889/metrics`
```
curl http://localhost:8889/metrics
```

Open the required ports on your firewall as needed, for example to be able to view the Grafana dashbaord you will need to open port 3000. 
```
sudo ufw allow 3000/tcp
```

You will be able to access a grafana dashboard on `http://<your_own_ip_address>:3000` 

![image](https://github.com/user-attachments/assets/4f22bea3-4752-4fad-8c43-c2f0aee4bc0c)


The default dashboard is `Monad monitoring`, an additional dashboard has been added that is `Monad monitoring v2`. v2 adds some extra metrics however needs some extra config.


## Activate V2 dashboard

To use V2 you must schedule the collector script; it gathers the extra info the dashboard displays.

For Monad binary installation
````
* * * * * /home/monad/monad-monitoring/textfile-collector/script-data-collector-binary.sh >> /home/monad/error.log
````

For Monad docker installation
````
* * * * * /home/monad/monad-monitoring/textfile-collector/script-data-collector-docker.sh >> /home/monad/error.log
````

The binary collector reads consensus state from the systemd journal, so the user running it
needs journal access. It reads the TrieDB via `monad-mpt`, which needs root or a sudo rule:
````
sudo usermod -a -G systemd-journal monad
````

The docker collector still parses syslog, so for that variant grant `adm` instead:
````
sudo usermod -a -G adm monad
````

### Running it with systemd instead of cron

For the binary install, `textfile-collector/systemd/` provides a timer and a oneshot
service. Preferred over the cron entry above: failures land in the journal with a
status you can query, rather than in a log file nobody reads.

Install the script to a root-owned path, rather than pointing the unit at this
checkout. The service runs as root, and a checkout owned by an unprivileged user
would let that user choose what root executes.

````
sudo install -m 0755 -o root -g root \
    textfile-collector/script-data-collector-binary.sh \
    /usr/local/bin/monad-textfile-collector

sudo install -m 0644 -o root -g root \
    textfile-collector/systemd/monad-textfile-collector.service \
    textfile-collector/systemd/monad-textfile-collector.timer \
    /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl enable --now monad-textfile-collector.timer
````

Re-run the first command after pulling this repository, so the installed copy
tracks the checkout.

Check it:
````
systemctl list-timers monad-textfile-collector.timer
systemctl status monad-textfile-collector.service
````

Any of the variables in the table below can be set in
`/etc/default/monad-textfile-collector`, which the service reads if present:
````
TARGET_DRIVE=triedb
MONAD_HOME=/home/monad/monad-bft
OUTPUT_FILE=/home/myuser/monad-monitoring/textfile-collector/data/monad-metrics-data.prom
````

The interval lives in the timer rather than that file, because systemd parses
`[Timer]` itself and does not expand environment variables there. To change it:
````
sudo systemctl edit monad-textfile-collector.timer
````


### Paths and overrides

The binary collector takes its paths from the environment, so it works regardless of where the
repository is checked out. Defaults preserve the original behaviour:

| Variable | Default | Purpose |
|---|---|---|
| `TARGET_DRIVE` | from `MONAD_ENV_FILE`, else `triedb` | Device holding the TrieDB |
| `MONAD_HOME` | `/home/monad/monad-bft` | Node data directory |
| `MONAD_ENV_FILE` | `/home/monad/.env` | Where `TARGET_DRIVE` is read from |
| `JOURNAL_UNIT` | `monad-bft` | Unit to read consensus state from |
| `JOURNAL_LINES` | `2000` | Journal lines to scan |
| `OUTPUT_FILE` | `<script dir>/data/monad-metrics-data.prom` | Metrics file node_exporter reads |

### Detecting a stalled collector

The collector publishes `mc_collector_last_success_timestamp_seconds`. If it stops running, every
other `mc_*` metric silently holds its last value, so dashboards and alerts keep reading as healthy
while the data is arbitrarily old. Alert on the heartbeat rather than trusting the gauges:

````
time() - mc_collector_last_success_timestamp_seconds > 600
````

### Block proposal metrics

`mc_block_proposal` is no longer emitted. It was scraped from log lines (`proposed_block`,
`finalized_block`, `timeout`) that current Monad releases no longer write, and it encoded `round`,
`seq_num` and `time_stamp` as labels, which grows unbounded series. The node's own metrics cover
the same ground:

| Replaces | Use |
|---|---|
| `mc_block_proposal{type="proposed"}` | `rate(monad_bft_txpool_create_proposal[5m])` |
| `mc_block_proposal{type="finalized"}` | `rate(monad_state_consensus_events_commit_block[5m])` |
| `mc_block_proposal{type="timeout"}` | `rate(monad_state_consensus_events_local_timeout[5m])` |

## Activate V3 dashboard

To use V3 you must you must have monad-ledger-tail installed and running. At this moment it only works with binary installation 
```
sudo systemctl daemon-reload
sudo systemctl restart monad-ledger-tail
```

## Dashboard Differences

Monad is evolving quickly, and as it does, we continue to add new dashboards to capture additional insights and support different installation types. To ensure compatibility, we’ve retained previous dashboard versions to accommodate older Monad setups.

v1 was the first release

v2 is v1 with the following additional metrics
- monad specific stats like round, epoch, etc
- triedb usage stats
- monad folders that should be cleared and monitored occasionally
- additional disk metrics

v3 is v2 with the following additional metrics
- monad consensus info around proposed & skipped blocks


