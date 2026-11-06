# Builds data/us-centers-of-population.csv from the Census Bureau's table of
# mean centers of population, 1790-2020. The Bureau publishes these only as an
# HTML table, so we read it once here and keep the result with the book.
#
# Run from the book's root folder: Rscript data-raw/centers-of-population.R

library(tidyverse)
library(rvest)

url <- "https://www.census.gov/geographies/reference-files/time-series/geo/centers-population/united-states.html"

raw <- read_html(url) |>
  html_element("table") |>
  html_table(header = FALSE)

# The table has subheader rows ("United States", "Coterminous United States")
# and lists 1950 twice: once for the 50 states, once for the lower 48.
centers <- raw |>
  set_names(c("year", "lat", "lon_west", "location")) |>
  mutate(
    extent = case_when(
      str_detect(year, "^Coterminous") ~ "Lower 48",
      str_detect(year, "^United States") ~ "50 states"
    )
  ) |>
  fill(extent) |>
  filter(str_detect(year, "^\\d{4}$")) |>
  transmute(
    year     = as.integer(year),
    extent,
    lat      = as.numeric(lat),
    lon      = -as.numeric(lon_west),  # the table reports degrees west
    # Footnote markers end up glued to the text ("Parkersburg2", "18512.")
    location = location |>
      str_replace("(\\d{4})\\d(\\.?)$", "\\1\\2") |>
      str_replace("([A-Za-z])\\d$", "\\1") |>
      str_squish()
  ) |>
  arrange(year, extent)

stopifnot(
  nrow(centers) == 25,
  all(between(centers$lat, 36, 40)),
  all(between(centers$lon, -93, -76))
)

dir.create("data", showWarnings = FALSE)
write_csv(centers, "data/us-centers-of-population.csv")
