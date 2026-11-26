// QualityPickerView.swift
// HAo Live — quality + line picker sheet for the room page.
// Lists only what the platform actually offered.

import SwiftUI

struct QualityPickerView: View {
    let streams: [PlayStream]
    let selectedStream: PlayStream?
    var onSelect: (PlayStream) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(StreamPicker.qualities(of: streams), id: \.self) { quality in
                    Section(quality) {
                        ForEach(StreamPicker.lines(of: streams, quality: quality), id: \.self) { line in
                            if let stream = streams.first(where: { $0.quality == quality && $0.line == line }) {
                                Button {
                                    onSelect(stream)
                                    dismiss()
                                } label: {
                                    HStack {
                                        Text(line)
                                        Spacer()
                                        if stream.id == selectedStream?.id {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("画质与线路")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}
