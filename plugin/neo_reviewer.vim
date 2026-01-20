if exists('g:loaded_neo_reviewer')
  finish
endif
let g:loaded_neo_reviewer = 1

lua require("neo_reviewer.plugin").setup()
