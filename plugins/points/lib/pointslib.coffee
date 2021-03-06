_     = require "underscore"
async = require "async"
utils = require "../../../lib/utils"

module.exports = (config) ->
  schema = require("./schema").load(config)
  api_methods = require("../../../lib/api_methods")(config)

  pl = {}

  pl.save_pointset = (session, data, callback) ->
    return callback("Missing model param") unless data?.model
    schema.PointSet.findOne {_id: data.model._id}, (err, doc) ->
      return callback(err) if err?
      if not doc
        doc = new schema.PointSet()
        event_type = "create"
      else
        event_type = "update"
      return callback("Permission denied") unless utils.can_edit(session, doc)
      delete data.model.sharing unless utils.can_change_sharing(session, doc)

      # Set fields
      for key in ["name", "slug"]
        doc[key] = data.model[key] if data.model[key]?
      if data.model.sharing?
        _.extend(doc.sharing, data.model.sharing)
      
      # Save
      doc.save (err, doc) ->
        return callback(err) if err?
        return callback("null doc") unless doc?
        pl.post_event_and_search session, doc, {type: event_type}, 0, (err, event, si) ->
          return callback(err) if err?
          return callback(null, doc, event, si)

  pl.post_event = (session, pointset, opts, timeout, callback) ->
    event = _.extend {
      application: "points"
      entity_url: pointset.url
      entity: pointset.id
      user: session.auth?.user_id
      via_user: session.auth?.user_id
      group: pointset.sharing?.group_id
      data: {
        title: pointset.name
        slug: pointset.slug
      }
    }, opts
    api_methods.post_event(event, timeout, callback)

  pl.post_search_index = (pointset, callback=(->)) ->
    search_data = {
      application: "points"
      entity: pointset.id
      type: "pointset"
      url: pointset.url
      summary: pointset.name
      title: pointset.name
      sharing: pointset.sharing
      text: [pointset.name].concat(
        point.revisions[0]?.text for point in pointset.points
      ).concat(
        point.revisions[0]?.text for point in pointset.drafts
      ).join("\n")
    }
    api_methods.add_search_index(search_data, callback)

  pl.post_event_and_search = (session, doc, event_opts, timeout, callback) ->
    async.parallel [
      (done) -> pl.post_event(session, doc, event_opts, timeout, done)
      (done) -> pl.post_search_index(doc, done)
    ], (err, results) ->
      return callback(err) if err?
      [event, si] = results
      return callback(err, event, si)

  pl.fetch_pointset_list = (session, callback) ->
    utils.list_accessible_documents schema.PointSet, session, (err, docs) ->
      return callback(err) if err?
      return callback(null, docs)

  pl.fetch_pointset = (slug, session, callback) ->
    schema.PointSet.findOne {slug: slug}, (err, doc) ->
      return callback(err) if err?
      return callback("PointSet #{slug} Not found") unless doc?
      return callback("Permission denied") unless utils.can_view(session, doc)
      return callback(null, doc)

  get_point = (session, data, required, callback) ->
    for key in required
      return callback("Missing param #{key}") unless data[key]?
    schema.PointSet.findOne {_id: data._id}, (err, doc) ->
      return callback(err) if err?
      return callback("Not found") unless doc?
      return callback("Permission denied") unless utils.can_edit(session, doc)
      if data.point_id
        point = doc.find_point(data.point_id)
        if not point?
          return callback("Point with id #{data.point_id} not found")
      return callback(null, doc, point)

  pl.revise_point = (session, data, callback) ->
    user_id = null
    if (data.user_id? and utils.is_authenticated(session) and
        session.users[data.user_id]?)
      user_id = data.user_id
    unless user_id or data.name?
      return callback("Missing user_id or name.")
    get_point session, data, ["_id", "text"], (err, doc, point) ->
      return callback(err) if err?
      if not point?
        doc.drafts.unshift({ revisions: []})
        point = doc.drafts[0]

      point.revisions.unshift({})
      rev = point.revisions[0]
      rev.text = data.text
      rev.supporters = []
      rev.supporters.push({
        user_id: user_id
        name: data.name
      })
      doc.save (err, doc) ->
        return callback(err) if err?
        return callback("null doc") unless doc?
        pl.post_event_and_search session, doc, {type: "update"}, 0, (err, event, si) ->
          return callback(err) if err?
          return callback(null, doc, point, event, si)

  pl.change_support = (session, data, callback) ->
    unless data.name or data.user_id
      return callback("Missing one of name or user_id")
    get_point session, data, ["_id", "point_id", "vote"], (err, doc, point) ->
      return callback(err) if err?
      rev = point.revisions[0]
      supporter_matches = (s) -> return (
          (data.user_id? and s.user_id? and
            s.user_id.toString() == data.user_id.toString()) or
          ((not data.user_id) and (not s.user_id) and
            s.name? and data.name?  and s.name == data.name)
        )

      if data.vote
        unless _.find(rev.supporters, supporter_matches)
          rev.supporters.push({user_id: data.user_id, name: data.name})
      else
        rev.supporters = _.reject(rev.supporters, supporter_matches)

      doc.save (err, doc) ->
        return callback(err) if err?
        return callback("null doc") unless doc?
        pl.post_event session, doc, {
          type: "vote"
          user: data.user_id
          via_user: session.auth?.user_id
          data: {
            title: doc.name
            action: {
              support: data.vote
              point_id: point._id
              user_id: data.user_id
              name: data.name
            }
          }
        }, 0, (err, event) ->
          return callback(err) if err?
          return callback(null, doc, point, event)

  pl.set_editing = (session, data, callback) ->
    get_point session, data, ["_id", "point_id", "editing"], (err, doc, point) ->
      return callback(err) if err?
      if data.editing
        point.editing.push(session.anon_id)
      else
        point.editing = _.without(point.editing, session.anon_id)
      doc.save (err, doc) -> callback(err, doc, point)

  pl.set_approved = (session, data, callback) ->
    get_point session, data, ["_id", "point_id", "approved"], (err, doc, point) ->
      return callback(err) if err?
      is_approved = doc.is_approved(point)
      if data.approved == is_approved
        # No change -- must be out of sync.
        return callback("No change")
      else
        if data.approved
          # Move from drafts to points.
          doc.drafts = _.reject(doc.drafts, (p) -> p._id == point._id)
          doc.points.push(point)
        else
          # Move from points to drafts.
          doc.points = _.reject(doc.points, (p) -> p._id == point._id)
          doc.drafts.unshift(point)
        doc.save (err, doc) -> callback(err, doc, point)
  
  pl.move_point = (session, data, callback) ->
    get_point session, data, ["_id", "point_id", "position"], (err, doc, point) ->
      return callback(err) if err?
      list = if doc.is_approved(point) then doc.points else doc.drafts
      if isNaN(data.position) or data.position < 0 or data.position >= list.length
        return callback("Bad position #{data.position}", doc)

      start_pos = null
      for p,i in list
        if p._id == point._id
          start_pos = i
          break
      unless start_pos?
        throw new Error("Unmatched point id #{point._id}")
      
      if start_pos == data.position
        # No change -- must be out of sync.
        return callback("No change", doc)

      # Remove the point from its current position.
      list.splice(start_pos, 1)
      # Insert it to the revised destination.
      list.splice(data.position, 0, point)
      doc.save (err, doc) -> callback(err, doc, point)

  pl.get_events = (session, data, callback) ->
    return callback("Missing pointset ID") unless data._id?
    schema.PointSet.findOne {_id: data._id}, 'session', (err, doc) ->
      return callback(err) if err?
      return callback("Not found") unless doc?
      return callback("Permission denied") unless utils.can_view(session, doc)
      api_methods.get_events {
        application: "points"
        entity: doc._id
      }, (err, events) ->
        return callback(err) if err?
        return callback(null, events)

  return pl
