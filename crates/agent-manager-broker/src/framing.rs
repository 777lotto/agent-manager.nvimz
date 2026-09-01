//! Bounded newline framing shared by child-process protocol adapters.

use tokio::io::{AsyncBufRead, AsyncBufReadExt};

pub(crate) enum BoundedFrame {
    Closed,
    Data(Vec<u8>),
    TooLarge,
}

pub(crate) async fn read_bounded_line<R>(
    reader: &mut R,
    max_payload_bytes: usize,
) -> std::io::Result<BoundedFrame>
where
    R: AsyncBufRead + Unpin,
{
    let mut frame = Vec::new();
    loop {
        let available = reader.fill_buf().await?;
        if available.is_empty() {
            return if frame.is_empty() {
                Ok(BoundedFrame::Closed)
            } else {
                Ok(BoundedFrame::Data(frame))
            };
        }

        let newline = available.iter().position(|byte| *byte == b'\n');
        let payload_bytes = newline.unwrap_or(available.len());
        if frame.len().saturating_add(payload_bytes) > max_payload_bytes {
            return Ok(BoundedFrame::TooLarge);
        }

        let consumed = newline.map_or(available.len(), |position| position + 1);
        frame.extend_from_slice(&available[..consumed]);
        reader.consume(consumed);
        if newline.is_some() {
            return Ok(BoundedFrame::Data(frame));
        }
    }
}

#[cfg(test)]
mod tests {
    use tokio::io::BufReader;

    use super::{BoundedFrame, read_bounded_line};

    #[tokio::test]
    async fn accepts_exact_limit_and_leaves_the_next_frame_buffered() {
        let mut reader = BufReader::new(&b"1234\nnext\n"[..]);
        let BoundedFrame::Data(first) = read_bounded_line(&mut reader, 4)
            .await
            .expect("first frame")
        else {
            panic!("expected first data frame");
        };
        assert_eq!(first, b"1234\n");

        let BoundedFrame::Data(second) = read_bounded_line(&mut reader, 4)
            .await
            .expect("second frame")
        else {
            panic!("expected second data frame");
        };
        assert_eq!(second, b"next\n");
    }

    #[tokio::test]
    async fn rejects_oversized_frame_without_allocating_the_remainder() {
        let mut reader = BufReader::new(&b"12345\n"[..]);
        let frame = read_bounded_line(&mut reader, 4)
            .await
            .expect("bounded read");
        assert!(matches!(frame, BoundedFrame::TooLarge));
    }
}
