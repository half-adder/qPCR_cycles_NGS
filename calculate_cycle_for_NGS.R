#!/usr/bin/env Rscript

# Load the required libraries
library("readxl")
suppressMessages(library("tidyverse"))
library(ggplot2)
library(paletteer)
library(dplyr)
library(tidyr)
library(purrr)
library(ggplot2)
library(tools)

# Get the data from the command line
if (length(args) == 0) {
  stop("Please provide the path to the qPCR data file")
}

################################################################################
# Common Function Definitions
################################################################################

# Plots line traces for grouped and colored  by `filter_column`. Samples are
# filtered to contain only those listed in `sample_list`.
# X and Y axis of plot can be specified.
plot_traces <- function(df, sample_list, filter_column = Sample.Name, x = Cycle, y = `Delta Rn`) {
  filtered_df <- df %>%
    filter({{ filter_column }} %in% sample_list)

  p <- ggplot(data = filtered_df, aes(x = {{ x }}, y = {{ y }}, group = {{ filter_column }})) +
    geom_line(aes(color = {{ filter_column }})) +
    geom_point() +
    scale_x_continuous(breaks = seq(0, 40, 2)) +
    theme_bw()

  return(p)
}

# Define the sigmoidal model
sigmoid_model <- function(Cycle, a, b, c) {
  a / (1 + exp(-b * (Cycle - c)))
}

# Fit the sigmoidal model to each sample
fit_sigmoid_model <- function(data) {
  tryCatch(
    {
      fit <- nls(`Delta Rn` ~ sigmoid_model(Cycle, a, b, c), data = data, start = list(a = 1, b = 1, c = 20))
      return(coef(fit))
    },
    error = function(e) {
      return(c(a = NA, b = NA, c = NA))
    }
  )
}

# Calculate the x value where y = thresh for each sample
calculate_x_at_y_thresh <- function(a, b, c, thresh) {
  if (is.na(a) || is.na(b) || is.na(c)) {
    return(NA)
  }
  return(c - log(a / thresh - 1) / b)
}

# Calculate the average value of the function in the last 10 cycles
calculate_avg_last_10_cycles <- function(data, a, b, c) {
  last_10_cycles <- tail(data$Cycle, 10)
  values <- sigmoid_model(last_10_cycles, a, b, c)
  return(mean(values, na.rm = TRUE))
}

################################################################################
# Calculations
################################################################################

# Load command line arguments
args <- commandArgs(trailingOnly = TRUE)

# Load the qPCR data
qpcr_data_path <- args[1]

# TODO: why skip 46? Always?
samples <- tibble(read_excel(qpcr_data_path, 1, skip = 46))

all_sample_names <- na.omit(unique(samples$`Sample Name`))

# Amplification DataFrame
amp <- tibble(read_excel(qpcr_data_path, 2, skip = 46)) %>%
  drop_na() %>%
  inner_join(., samples, by = join_by(Well, `Target Name`)) %>%
  rename(Sample.Name = `Sample Name`)

# Apply the model fitting to each sample, excluding NTC
exp_fits <- amp %>%
  filter(Sample.Name != "NTC") %>%
  group_by(Sample.Name) %>%
  nest() %>%
  mutate(fit = map(data, fit_sigmoid_model)) %>%
  mutate(avg_last_10_cycles = map2_dbl(data, fit, ~ calculate_avg_last_10_cycles(.x, .y[1], .y[2], .y[3]))) %>%
  unnest_wider(fit)

# Calculate threshold as 1/4 of the average of the last 10 cycles for each sample
thresh <- mean(exp_fits$avg_last_10_cycles) / 4

exp_fits <- exp_fits %>%
  mutate(x_at_y_thresh = mapply(calculate_x_at_y_thresh, a, b, c, MoreArgs = list(thresh = thresh))) %>%
  mutate(cycle_thresh = round(x_at_y_thresh))


################################################################################
# Outputs
################################################################################

samples_basename <- file_path_sans_ext(qpcr_data_path)
plot_path <- paste0(samples_basename, "_AMPLIFICATION", ".png")
cycles_path <- paste0(samples_basename, "_CYCLES", ".csv")

# Plot the fitted curves and vertical lines
png(plot_path, width = 1000, height = 600)
ggplot(amp, aes(x = Cycle, y = `Delta Rn`, color = Sample.Name)) +
  geom_point() +
  geom_line(data = exp_fits %>% unnest(data), aes(y = sigmoid_model(Cycle, a, b, c)), linetype = "dashed") +
  geom_hline(yintercept = thresh, linetype = "dashed") +
  geom_vline(data = exp_fits, aes(xintercept = cycle_thresh), linetype = "dotted")
garbage <- dev.off()

message(paste0("Saved plot to: ", plot_path))

write_csv(exp_fits %>% select(Sample.Name, cycle_thresh) %>% arrange(cycle_thresh), cycles_path)

message(paste0("Saved cycle thresholds to: ", cycles_path))

print(
  exp_fits %>% select(Sample.Name, cycle_thresh) %>% arrange(cycle_thresh),
  row.names = FALSE, dims = FALSE, classes = FALSE
)
