# Copyright (c) Microsoft Corporation.  All rights reserved.

# frozen_string_literal: true

require "logger"
require "yajl/json_gem"
require "time"
require_relative "oms_common"
require_relative "CustomMetricsUtils"
require_relative "MdmMetricsGenerator"
# require_relative "mdmMetrics"
require_relative "constants"

class Inventory2MdmConvertor
  @@node_count_metric_name = "nodesCount"
  @@pod_count_metric_name = "podCount"
  #   @@oom_killed_container_count_metric_name = "OomKilledContainerCount"
  #   @container_restart_count_metric_name = "ContainerRestartCount"
  @@pod_inventory_tag = "mdm.kubepodinventory"
  @@node_inventory_tag = "mdm.kubenodeinventory"
  @@node_status_ready = "Ready"
  @@node_status_not_ready = "NotReady"
  @@oom_killed = "oomkilled"

  @@node_inventory_custom_metrics_template = '
        {
            "time": "%{timestamp}",
            "data": {
                "baseData": {
                    "metric": "%{metricName}",
                    "namespace": "insights.container/nodes",
                    "dimNames": [
                    "status"
                    ],
                    "series": [
                    {
                        "dimValues": [
                        "%{statusValue}"
                        ],
                        "min": %{node_status_count},
                        "max": %{node_status_count},
                        "sum": %{node_status_count},
                        "count": 1
                    }
                    ]
                }
            }
        }'

  @@pod_inventory_custom_metrics_template = '
        {
            "time": "%{timestamp}",
            "data": {
                "baseData": {
                    "metric": "%{metricName}",
                    "namespace": "insights.container/pods",
                    "dimNames": [
                    "phase",
                    "Kubernetes namespace",
                    "node",
                    "controllerName"
                    ],
                    "series": [
                    {
                        "dimValues": [
                        "%{phaseDimValue}",
                        "%{namespaceDimValue}",
                        "%{nodeDimValue}",
                        "%{controllerNameDimValue}"
                        ],
                        "min": %{podCountMetricValue},
                        "max": %{podCountMetricValue},
                        "sum": %{podCountMetricValue},
                        "count": 1
                    }
                    ]
                }
            }
        }'

  @@pod_phase_values = ["Running", "Pending", "Succeeded", "Failed", "Unknown"]
  @process_incoming_stream = false

  def initialize(custom_metrics_azure_regions)
    @log_path = "/var/opt/microsoft/docker-cimprov/log/mdm_metrics_generator.log"
    @log = Logger.new(@log_path, 1, 5000000)
    @pod_count_hash = {}
    @no_phase_dim_values_hash = {}
    @pod_count_by_phase = {}
    @pod_uids = {}
    @process_incoming_stream = CustomMetricsUtils.check_custom_metrics_availability(custom_metrics_azure_regions)
    @log.debug "After check_custom_metrics_availability process_incoming_stream #{@process_incoming_stream}"
    @log.debug { "Starting podinventory_to_mdm plugin" }
  end

  def get_pod_inventory_mdm_records(batch_time)
    begin
      # generate all possible values of non_phase_dim_values X pod Phases and zero-fill the ones that are not already present
      @no_phase_dim_values_hash.each { |key, value|
        @@pod_phase_values.each { |phase|
          pod_key = [key, phase].join("~~")
          if !@pod_count_hash.key?(pod_key)
            @pod_count_hash[pod_key] = 0
            #@log.info "Zero filled #{pod_key}"
          else
            next
          end
        }
      }
      records = []
      @pod_count_hash.each { |key, value|
        key_elements = key.split("~~")
        if key_elements.length != 4
          next
        end

        # get dimension values by key
        podNodeDimValue = key_elements[0]
        podNamespaceDimValue = key_elements[1]
        podControllerNameDimValue = key_elements[2]
        podPhaseDimValue = key_elements[3]

        record = @@pod_inventory_custom_metrics_template % {
          timestamp: batch_time,
          metricName: @@pod_count_metric_name,
          phaseDimValue: podPhaseDimValue,
          namespaceDimValue: podNamespaceDimValue,
          nodeDimValue: podNodeDimValue,
          controllerNameDimValue: podControllerNameDimValue,
          podCountMetricValue: value,
        }
        records.push(JSON.parse(record))
      }

      #Add pod metric records
      records = MdmMetricsGenerator.appendAllPodMetrics(records, batch_time)
    rescue Exception => e
      @log.info "Error processing pod inventory record Exception: #{e.class} Message: #{e.message}"
      ApplicationInsightsUtility.sendExceptionTelemetry(e.backtrace)
      return []
    end
    @log.info "Pod Count To Phase #{@pod_count_by_phase} "
    @log.info "resetting convertor state "
    @pod_count_hash = {}
    @no_phase_dim_values_hash = {}
    @pod_count_by_phase = {}
    @pod_uids = {}
    return records
  end

  #   def process_record_for_oom_killed_metric(containerLastStatus, podControllerNameDimValue, podNamespaceDimValue)
  #     begin
  #       @log.info "in process_record_for_oom_killed_metric..."
  #       # Generate metric if 'reason' for lastState is 'OOMKilled'
  #       if !containerLastStatus.nil? && !containerLastStatus.empty?
  #         reason = containerLastStatus["reason"]
  #         if !reason.nil? &&
  #            !reason.empty? &&
  #            reason.downcase == @@oom_killed
  #           MdmMetricsGenerator.generatePodMetrics(MdmMetrics::OOM_KILLED_CONTAINER_COUNT,
  #                                                  podControllerNameDimValue,
  #                                                  podNamespaceDimValue)
  #         end
  #       end
  #     rescue => errorStr
  #       @log.warn("Exception in process_record_for_oom_killed_metric: #{errorStr}")
  #       ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
  #     end
  #   end

  # Check if container was terminated in the last 5 minutes
  def is_container_terminated_recently(finishedTime)
    begin
      if !finishedTime.nil? && !finishedTime.empty?
        finishedTimeParsed = Time.parse(finishedTime)
        if ((Time.now - finishedTimeParsed) / 60) < Constants::CONTAINER_TERMINATED_RECENTLY_IN_MINUTES
          return true
        end
      end
    rescue => errorStr
      @log.warn("Exception in check_if_terminated_recently: #{errorStr}")
      ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
    end
    return false
  end

  def process_record_for_oom_killed_metric(podControllerNameDimValue, podNamespaceDimValue, finishedTime)
    begin
      @log.info "in process_record_for_oom_killed_metric..."
      if podControllerNameDimValue.nil? || podControllerNameDimValue.empty?
        podControllerNameDimValue = "No Controller"
      end

      # Send OOM Killed state for container only if it terminated in the last 5 minutes, we dont want to keep sending this count forever
      if is_container_terminated_recently(finishedTime)
        MdmMetricsGenerator.generateOOMKilledPodMetrics(podControllerNameDimValue,
                                                        podNamespaceDimValue)
      end
    rescue => errorStr
      @log.warn("Exception in process_record_for_oom_killed_metric: #{errorStr}")
      ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
    end
  end

  def process_record_for_container_restarts_metric(podControllerNameDimValue, podNamespaceDimValue, finishedTime)
    begin
      @log.info "in process_record_for_container_restarts_metric..."
      if podControllerNameDimValue.nil? || podControllerNameDimValue.empty?
        podControllerNameDimValue = "No Controller"
      end

      # Send OOM Killed state for container only if it terminated in the last 5 minutes, we dont want to keep sending this count forever
      if is_container_terminated_recently(finishedTime)
        MdmMetricsGenerator.generateContainerRestartsMetrics(podControllerNameDimValue,
                                                             podNamespaceDimValue)
      end
    rescue => errorStr
      @log.warn("Exception in process_record_for_container_restarts_metric: #{errorStr}")
      ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
    end
  end

  def process_pod_inventory_record(record)
    if @process_incoming_stream
      begin
        records = []

        podUid = record["DataItems"][0]["PodUid"]
        if @pod_uids.key?(podUid)
          #@log.info "pod with #{podUid} already counted"
          return
        end

        @pod_uids[podUid] = true
        podPhaseDimValue = record["DataItems"][0]["PodStatus"]
        podNamespaceDimValue = record["DataItems"][0]["Namespace"]
        podControllerNameDimValue = record["DataItems"][0]["ControllerName"]
        podNodeDimValue = record["DataItems"][0]["Computer"]

        if podControllerNameDimValue.nil? || podControllerNameDimValue.empty?
          podControllerNameDimValue = "No Controller"
        end

        if podNodeDimValue.empty? && podPhaseDimValue.downcase == "pending"
          podNodeDimValue = "unscheduled"
        elsif podNodeDimValue.empty?
          podNodeDimValue = "unknown"
        end

        # group by distinct dimension values
        pod_key = [podNodeDimValue, podNamespaceDimValue, podControllerNameDimValue, podPhaseDimValue].join("~~")

        @pod_count_by_phase[podPhaseDimValue] = @pod_count_by_phase.key?(podPhaseDimValue) ? @pod_count_by_phase[podPhaseDimValue] + 1 : 1
        @pod_count_hash[pod_key] = @pod_count_hash.key?(pod_key) ? @pod_count_hash[pod_key] + 1 : 1

        # Collect all possible combinations of dimension values other than pod phase
        key_without_phase_dim_value = [podNodeDimValue, podNamespaceDimValue, podControllerNameDimValue].join("~~")
        if @no_phase_dim_values_hash.key?(key_without_phase_dim_value)
          return
        else
          @no_phase_dim_values_hash[key_without_phase_dim_value] = true
        end

        #Generate OOM killed mdm metric
        # process_record_for_oom_killed_metric(record["DataItems"][0]["ContainerLastStatus"], podControllerNameDimValue, podNamespaceDimValue)
        #Generate Container restarts mdm metric
        # process_record_for_container_restarts_metric(record["DataItems"][0]["ContainerRestartCount"], podControllerNameDimValue, podNamespaceDimValue)
        # process_record_for_container_restarts_metric(record["DataItems"][0]["PodRestartCount"], podControllerNameDimValue, podNamespaceDimValue)
      rescue Exception => e
        @log.info "Error processing pod inventory record Exception: #{e.class} Message: #{e.message}"
        ApplicationInsightsUtility.sendExceptionTelemetry(e.backtrace)
      end
    end
  end
end
