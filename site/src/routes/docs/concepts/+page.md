---
title: Concepts
order: 2
---

# Concepts

Sideshowdb treats Git as the source of truth and derives the working surface from repository history.

## Events

Events capture append-only changes so the history stays inspectable.

## Refs

Refs describe the active shape of a repository and define what users are looking at now.

## Derived Views

Derived views project repository data into documents and other readable forms.

## Public Playground

The first-release playground is intentionally read-only. It validates public
`owner/repo` input in the browser, fetches public GitHub data client-side, and
uses that data to explain how Sideshowdb would interpret the repository.
