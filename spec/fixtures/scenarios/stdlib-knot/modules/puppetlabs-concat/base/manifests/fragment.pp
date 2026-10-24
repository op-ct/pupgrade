define concat::fragment (String $content) {
  notify { "fragment ${title}": message => $content }
}
