
# Exporting Azure Metrics to Prometheus+Grafana

## Purpose

Exports Azure Monitor metrics to Prometheus, and configure the Grafana dashboard for visualization.<br>
In this guide, we take Azure Container Apps (ACA) running metrics as example, exporting them from Azure Monitor to Prometheus, and visualizes them using Grafana.

---

## Architecture

<div style="border: 2px solid #888; border-radius: 8px; padding: 8px; display: inline-block; margin: 8px 0;">
   <img src="prometheus/azmetricsexporter.png" alt="Azure Metrics Exporter Architecture" />
</div>

---

## Prerequisites

- An Azure service principal with permissions to read metrics from Azure Monitor.
- Use the provided Dockerfile in the [azure-metrics-exporter repository](https://github.com/webdevops/azure-metrics-exporter) to create a Docker image.

---

## azure-metrics-exporter Setup

### 1. Configure Azure Service Principal

Assign the **Contributor** role on the target one or more subscriptions to your Azure service principal.

### 2. Start the azure-metrics-exporter container

Replace placeholders with your actual values:

```sh
docker run -d -p 8080:8080 \
   -e AZURE_TENANT_ID="<your-tenant-id>" \
   -e AZURE_CLIENT_ID="<your-client-id>" \
   -e AZURE_CLIENT_SECRET="<your-client-secret>" \
   -e AZURE_SUBSCRIPTION_ID="<your-subscription-id>" \
   --restart=always --name azmetricsexporter \
   your-docker-image
```

### 3. Access the azure-metrics-exporter UI

Visit: `http://<host-ip>:8080/query`

### 4. Query ACA Metrics

Fill in the form as shown below:

<div style="border: 2px solid #888; border-radius: 8px; padding: 8px; display: inline-block; margin: 8px 0;">
   <img src="prometheus/azure-metrics-exporter-query-tester.png" alt="Azure Metrics Exporter Query" />
</div>

- **Endpoint:** `/probe/metrics/list`
- **Resource Type:** `Microsoft.App/containerapps`
- **Metric:** `Replicas`, `Requests`, `CpuPercentage`, `MemoryPercentage`  
   _(Above Metrics are for example only. For supported ACA metrics, refer to [Azure Container Apps Metrics](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/supported-metrics/microsoft-app-containerapps-metrics))_
- **Interval:** `PT15M`
- **Timespan:** `PT24H`

### 5. Execute Query

Click **Execute Query**. If successful, you will see a response like below:

<div style="border: 2px solid #888; border-radius: 8px; padding: 8px; display: inline-block; margin: 8px 0;">
   <img src="prometheus/azure-metrics-exporter-query-tester-return-metrics.png" alt="Azure Metrics Exporter Response" />
</div>

---

## Prometheus Integration

### 6. Get Prometheus Scrape Config

Copy the generated Prometheus scrape config for ACA metrics at the bottom of the page. Add it to your `prometheus.yml` file. Replace the `targets` line with your Azure Metrics Exporter endpoint, e.g. `<host-ip>:8080`:

<div style="border: 2px solid #888; border-radius: 8px; padding: 8px; display: inline-block; margin: 8px 0;">
   <img src="prometheus/azure-metrics-exporter-query-tester-return-promconfig.png" alt="Azure Metrics Exporter Prometheus Config" />
</div>

### 7. Restart Prometheus

Restart Prometheus to apply the changes. In the Prometheus UI, go to **Status → Target health** to verify the ACA metrics endpoint is up:

<div style="border: 2px solid #888; border-radius: 8px; padding: 8px; display: inline-block; margin: 8px 0;">
   <img src="prometheus/prometheus-target-health.png" alt="Azure Metrics Exporter Targets" />
</div>

### 8. Query in Prometheus

Go to the **Query** page in Prometheus UI and run queries like:

```promql
{__name__=~".*containerapps.*",timespan="PT24H"}
```

<div style="border: 2px solid #888; border-radius: 8px; padding: 8px; display: inline-block; margin: 8px 0;">
   <img src="prometheus/prometheus-query-metrics.png" alt="Azure Metrics Exporter Prometheus Query" />
</div>

If you see metrics data, Prometheus is successfully scraping ACA metrics from Azure Metrics Exporter.

---

## Grafana Integration

### 9. Add Prometheus as Data Source

In Grafana, add Prometheus as a data source. Enter the correct Prometheus server URL and configure authentication as needed:

<div style="border: 2px solid #888; border-radius: 8px; padding: 8px; display: inline-block; margin: 8px 0;">
   <img src="prometheus/grafana-prom-datasource.png" alt="Grafana Add Data Source" />
</div>

### 10. Create Dashboards

You can now create dashboards to visualize ACA metrics. Create your own or import from Grafana's dashboard repository. See the sample video below for reference:<br>
https://github.com/user-attachments/assets/fa1f0a71-106a-41ac-8039-dc66cc11deca

### 11. View ACA Apps in Grafana

You can now view multiple ACA apps in your Grafana dashboard:

<div style="border: 2px solid #888; border-radius: 8px; padding: 8px; display: inline-block; margin: 8px 0;">
   <img src="prometheus/aca-azmon-prom-grafana.png" alt="Grafana ACA Dashboard" />
</div>
