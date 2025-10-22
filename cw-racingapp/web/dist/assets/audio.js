// Audio handler for CW Racing App
console.log('Audio handler loaded');

// Listen for NUI messages
window.addEventListener('message', function(event) {
    const data = event.data;
    
    if (data.type === 'playCustomSound' && data.soundFile) {
        console.log('Playing custom sound:', data.soundFile);
        playAudioFile(data.soundFile);
    }
    
    if (data.type === 'playAudioFile' && data.file) {
        console.log('Playing audio file:', data.file);
        playAudioFile(data.file);
    }
});

function playAudioFile(filename) {
    try {
        // Try multiple paths for the audio file
        const paths = [
            `./${filename}`,
            `../${filename}`,
            `/${filename}`,
            `nui://cw-racingapp/${filename}`
        ];
        
        let audioElement = null;
        
        // Try each path until one works
        for (const path of paths) {
            try {
                console.log('Trying audio path:', path);
                audioElement = new Audio(path);
                audioElement.volume = 0.7;
                audioElement.preload = 'auto';
                
                // Test if the audio can load
                audioElement.addEventListener('canplaythrough', () => {
                    console.log('Audio can play, attempting to play:', path);
                    audioElement.play().then(() => {
                        console.log('Audio played successfully:', path);
                    }).catch((playError) => {
                        console.error('Error playing audio:', playError);
                    });
                });
                
                audioElement.addEventListener('error', (error) => {
                    console.log('Audio path failed:', path, error);
                    if (paths.indexOf(path) === paths.length - 1) {
                        console.error('All audio paths failed');
                    }
                });
                
                // Try to load the audio
                audioElement.load();
                
                // Clean up after playing
                audioElement.addEventListener('ended', () => {
                    audioElement.remove();
                });
                
                break; // Stop trying other paths if this one works
                
            } catch (pathError) {
                console.log('Path error for:', path, pathError);
                continue;
            }
        }
        
    } catch (error) {
        console.error('Error creating audio element:', error);
    }
}

console.log('Audio handler ready');
