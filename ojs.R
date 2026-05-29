# ojs.R — a thin authenticated client for the OJS (Open Journal Systems) REST API
#
# Scope: just enough of the OJS 3.4 REST API to build the CCR journal-health report.
# Written as pure functions (no top-level side effects) so this file can later be
# promoted to an R package by dropping it into R/ and running usethis::create_package().
#
# Nothing here is CCR-specific: base URL and token are arguments, defaulting to the
# OJS_BASE_URL / OJS_TOKEN environment variables (see .env). The token is a secret —
# never hardcode it or print it.
#
# Deps: httr2, jsonlite, tibble, dplyr, purrr.

library(httr2)
library(tibble)
library(dplyr)
library(purrr)

# ---- client -----------------------------------------------------------------

#' Create an OJS API client
#'
#' @param base_url Journal base URL, e.g. "https://journal.computationalcommunication.org".
#'   The "/api/v1" suffix is added automatically if absent.
#' @param token API token (OJS apiToken). Defaults to env var OJS_TOKEN.
#' @return A list with class "ojs_client".
ojs_client <- function(base_url = Sys.getenv("OJS_BASE_URL"),
                       token    = Sys.getenv("OJS_TOKEN")) {
  if (!nzchar(base_url)) stop("ojs_client(): base_url is empty (set OJS_BASE_URL).")
  if (!nzchar(token))    stop("ojs_client(): token is empty (set OJS_TOKEN).")
  base_url <- sub("/+$", "", base_url)
  if (!grepl("/api/v[0-9]+$", base_url)) base_url <- paste0(base_url, "/api/v1")
  structure(list(base_url = base_url, token = token), class = "ojs_client")
}

# Build a request for a given path, with auth + sane defaults. Internal.
.ojs_req <- function(client, path, query = list()) {
  stopifnot(inherits(client, "ojs_client"))
  query <- c(query, list(apiToken = client$token))
  # drop NULLs so callers can pass optional params as NULL
  query <- query[!vapply(query, is.null, logical(1))]
  request(client$base_url) |>
    req_url_path_append(sub("^/", "", path)) |>
    req_url_query(!!!query) |>
    req_user_agent("ojs.R (httr2)") |>
    req_retry(max_tries = 3, retry_on_failure = TRUE) |>
    req_timeout(60)
}

# ---- core GET helpers -------------------------------------------------------

#' GET a single endpoint, returning parsed JSON (list).
ojs_get <- function(client, path, query = list()) {
  resp <- .ojs_req(client, path, query) |> req_perform()
  resp_body_json(resp, simplifyVector = FALSE)
}

#' GET a list endpoint, auto-paginating over OJS's {items, itemsMax} envelope.
#'
#' @param path e.g. "/submissions", "/users".
#' @param query Extra query params (status, assignedTo, dateStart, ...).
#' @param page_size Items per page (OJS caps around 100 for most resources).
#' @param max_items Optional cap on total items fetched (NULL = all).
#' @return A list of item lists (length == itemsMax, unless capped).
ojs_get_all <- function(client, path, query = list(),
                        page_size = 100, max_items = NULL) {
  items <- list()
  offset <- 0L
  repeat {
    q <- c(query, list(count = page_size, offset = offset))
    body <- ojs_get(client, path, q)
    batch <- body$items %||% list()
    items <- c(items, batch)
    total <- body$itemsMax %||% length(items)
    offset <- offset + length(batch)
    if (length(batch) == 0L) break
    if (offset >= total) break
    if (!is.null(max_items) && length(items) >= max_items) break
  }
  if (!is.null(max_items) && length(items) > max_items) items <- items[seq_len(max_items)]
  items
}

`%||%` <- function(a, b) if (is.null(a)) b else a

# ---- resource helpers -------------------------------------------------------
# These return tidy tibbles of the fields the report needs. The raw list is always
# reachable via ojs_get()/ojs_get_all() if more fields are required later.

#' Submissions list (optionally filtered).
#'
#' @param status Optional OJS status code(s) (1=queued,3=published,4=declined,...).
#' @param assigned_to Optional editor userId — submissions assigned to that editor.
ojs_submissions <- function(client, status = NULL, assigned_to = NULL,
                            max_items = NULL) {
  q <- list(status = status, assignedTo = assigned_to)
  items <- ojs_get_all(client, "/submissions", query = q, max_items = max_items)
  map_dfr(items, function(s) {
    pub <- s$publications[[1]] %||% list()
    tibble(
      id            = s$id %||% NA_integer_,
      status        = s$status %||% NA_integer_,
      status_label  = s$statusLabel %||% NA_character_,
      stage_id      = s$stageId %||% NA_integer_,
      date_submitted = s$dateSubmitted %||% NA_character_,
      last_modified  = s$lastModified %||% NA_character_,
      section_id     = pub$sectionId %||% NA_integer_,
      authors_string = pub$authorsString %||% NA_character_,
      n_review_assignments = length(s$reviewAssignments %||% list()),
      n_review_rounds      = length(s$reviewRounds %||% list())
    )
  })
}

#' Count submissions assigned to an editor (cheap: reads only itemsMax).
ojs_assigned_count <- function(client, editor_id) {
  body <- ojs_get(client, "/submissions",
                  list(assignedTo = editor_id, count = 1, offset = 0))
  body$itemsMax %||% 0L
}

#' Full submission record (raw list): includes stages, reviewRounds, reviewAssignments.
ojs_submission <- function(client, id) {
  ojs_get(client, sprintf("/submissions/%s", id))
}

#' Editorial decisions for a submission, as a tibble.
ojs_decisions <- function(client, id) {
  decs <- ojs_get(client, sprintf("/submissions/%s/decisions", id))
  if (length(decs) == 0L) return(tibble(
    submission_id = integer(), decision_id = integer(), decision = integer(),
    label = character(), editor_id = integer(), stage_id = integer(),
    review_round_id = integer(), date_decided = character()))
  map_dfr(decs, function(d) tibble(
    submission_id   = id,
    decision_id     = d$id %||% NA_integer_,
    decision        = d$decision %||% NA_integer_,
    label           = d$label %||% NA_character_,
    editor_id       = d$editorId %||% NA_integer_,
    stage_id        = d$stageId %||% NA_integer_,
    review_round_id = d$reviewRoundId %||% NA_integer_,
    date_decided    = d$dateDecided %||% NA_character_
  ))
}

#' Decisions for many submissions in parallel (httr2 parallel requests).
#'
#' This is the report's heavy call (~500 submissions). Uses req_perform_parallel.
ojs_decisions_bulk <- function(client, ids, max_active = 10) {
  reqs <- map(ids, function(id) .ojs_req(client, sprintf("/submissions/%s/decisions", id)))
  resps <- req_perform_parallel(reqs, max_active = max_active, on_error = "continue")
  map2_dfr(ids, resps, function(id, resp) {
    if (inherits(resp, "error") || is.null(resp)) return(tibble())
    decs <- resp_body_json(resp, simplifyVector = FALSE)
    if (length(decs) == 0L) return(tibble())
    map_dfr(decs, function(d) tibble(
      submission_id   = id,
      decision_id     = d$id %||% NA_integer_,
      decision        = d$decision %||% NA_integer_,
      label           = d$label %||% NA_character_,
      editor_id       = d$editorId %||% NA_integer_,
      stage_id        = d$stageId %||% NA_integer_,
      review_round_id = d$reviewRoundId %||% NA_integer_,
      date_decided    = d$dateDecided %||% NA_character_
    ))
  })
}

#' Submission files at a given file stage, as a tibble.
#'
#' Useful stages: 2=submission, 4=review file, 5=review attachment,
#' 15=review-revision (author revisions after a review round).
ojs_files <- function(client, id, file_stage = 15) {
  out <- ojs_get(client, sprintf("/submissions/%s/files", id),
                 list(fileStages = file_stage))
  if (length(out$items) == 0L) return(tibble(
      submission_id = integer(), file_id = integer(),
      created_at = character(), uploader = character()
  ))
  # the API duplicates items per available locale of the genre name; dedupe
  # on (id, fileId) to get one row per uploaded file.
  map_dfr(out$items, function(it) tibble(
    submission_id = id,
    file_id       = it$fileId %||% NA_integer_,
    item_id       = it$id %||% NA_integer_,
    created_at    = it$createdAt %||% NA_character_,
    uploader      = it$uploaderUserName %||% NA_character_
  )) |> distinct(submission_id, file_id, created_at, uploader, .keep_all = FALSE)
}

#' Files for many submissions in parallel.
ojs_files_bulk <- function(client, ids, file_stage = 15, max_active = 10) {
  reqs <- map(ids, function(id) .ojs_req(
      client, sprintf("/submissions/%s/files", id),
      list(fileStages = file_stage)
  ))
  resps <- req_perform_parallel(reqs, max_active = max_active, on_error = "continue")
  map2_dfr(ids, resps, function(id, resp) {
    if (inherits(resp, "error") || is.null(resp)) return(tibble())
    out <- resp_body_json(resp, simplifyVector = FALSE)
    if (length(out$items) == 0L) return(tibble())
    map_dfr(out$items, function(it) tibble(
      submission_id = id,
      file_id       = it$fileId %||% NA_integer_,
      created_at    = it$createdAt %||% NA_character_,
      uploader      = it$uploaderUserName %||% NA_character_
    )) |> distinct()
  })
}

#' Editorial activity stats (decision funnel), optionally date-bounded.
#'
#' @param date_start,date_end "YYYY-MM-DD" strings (optional).
ojs_stats_editorial <- function(client, date_start = NULL, date_end = NULL) {
  rows <- ojs_get(client, "/stats/editorial",
                  list(dateStart = date_start, dateEnd = date_end))
  map_dfr(rows, function(r) tibble(
    key = r$key %||% NA_character_,
    name = r$name %||% NA_character_,
    value = r$value %||% NA_integer_
  ))
}

#' Per-article usage stats (views).
ojs_stats_publications <- function(client, date_start = NULL, date_end = NULL,
                                   max_items = NULL) {
  q <- list(dateStart = date_start, dateEnd = date_end)
  items <- ojs_get_all(client, "/stats/publications", query = q, max_items = max_items)
  map_dfr(items, function(it) {
    p <- it$publication %||% list()
    tibble(
      submission_id = p$id %||% NA_integer_,
      title         = (p$fullTitle$en %||% p$fullTitle[[1]]) %||% NA_character_,
      abstract_views = it$abstractViews %||% NA_integer_,
      galley_views   = it$galleyViews %||% NA_integer_,
      pdf_views      = it$pdfViews %||% NA_integer_,
      html_views     = it$htmlViews %||% NA_integer_,
      other_views    = it$otherViews %||% NA_integer_
    )
  })
}

#' Users with their role groups, as a tibble (one row per user; roles collapsed).
ojs_users <- function(client, max_items = NULL) {
  items <- ojs_get_all(client, "/users", max_items = max_items)
  map_dfr(items, function(u) {
    roles <- map_chr(u$groups %||% list(), function(g) g$name$en %||% NA_character_)
    tibble(
      id        = u$id %||% NA_integer_,
      full_name = u$fullName %||% NA_character_,
      email     = u$email %||% NA_character_,
      disabled  = u$disabled %||% NA,
      roles     = paste(roles, collapse = "; ")
    )
  })
}

#' Single user (raw list).
ojs_user <- function(client, id) ojs_get(client, sprintf("/users/%s", id))

#' Published issues.
ojs_issues <- function(client, max_items = NULL) {
  items <- ojs_get_all(client, "/issues", max_items = max_items)
  map_dfr(items, function(i) tibble(
    id = i$id %||% NA_integer_,
    date_published = i$datePublished %||% NA_character_
  ))
}
